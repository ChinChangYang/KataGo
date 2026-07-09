//
//  gr_detect.cpp
//  CGobanRecog
//
//  Ports part B of gobanrecog/pipeline/detect.py line-by-line (port-conventions
//  rule 1): the candidate EVALUATION / arbitration / refinement layer plus
//  detect_board. See gr_detect_internal.h for the exact A/B boundary; the four
//  quad proposers + _wood_mask (part A) live in gr_detect_proposers.cpp and are
//  consumed here through that seam. The gobanrecog::testbridge detect_* wrappers
//  are defined at the bottom of THIS file (the gr_grid/gr_stones/gr_stonelattice
//  pattern) so they reach the file-local statics.
//
//  dtype fidelity (rule 2), all probed against numpy 2.5.1 / cv2 5.0.0 in the
//  reference venv (Task 8 probes):
//    - _extension_counts: prof is a float32 line profile; ref = prof[idx].mean()
//      + 1e-9 is FLOAT32 (numpy mean of f32 stays f32; + weak python-float stays
//      f32); the walk threshold 0.55*ref and prof-window .max() are float32.
//    - lattice_quality / _stone_map / _measure_nodes: rect is uint8; blackhat
//      bh_v/bh_h are uint8 (their means are exact integer sums); stoneness =
//      abs(rect.astype(f32) - median(uint8)) is FLOAT64 (NEP-50: f32 array minus
//      an f64 scalar promotes); avg = filter2D(stoneness_f64, -1, _KER_f32) is
//      f64; nodes/cells/line_v/line_h/stone_v/stone_h are f64.
//    - _measure_nodes: cross = min(bh_v,bh_h).astype(f32); node gate
//      `wc.max() > max(0.35*cref, 8.0)` and DT gates `0.30*S < ws.max() <
//      0.55*S` compare in FLOAT32 (np.float32 scalar vs weak python-float ->
//      the python-float is cast to f32); node_max percentile is a float32
//      percentile; colprof/rowprof/subpix are float32.
//    - _cut_score: rect uint8; PAD/SPAN here are grid's RECT_PAD=150/SPAN=800
//      (detect.py imports PAD, SPAN from grid); refx = percentile(full_x_f32, 90)
//      is a float32 percentile; the cin_* means are exact uint8 integer means.
//    - stone_stats: stoneness f64; g/dist f64; np.linalg.norm(axis=1) = sqrt
//      (NOT hypot); A/resid f64; B an integer count.
//    - reduction order (Task 4): a 2-D `.mean()` and `.mean(axis=1)` are numpy
//      pairwise; `.mean(axis=0)` accumulates NAIVELY down the (strided) outer
//      axis. line_v[j]/stone_v[j] (axis=0 means) use naive column sums; nodes/
//      cells whole-array means and line_v.mean()/nodes.mean(axis=1) use pairwise.
//
//  Object-identity change signals (rule 4): _refine_H_nodes / _shift_search
//  return std::optional<cv::Mat> (nullopt = "no better H found", replacing
//  Python's return-the-same-object convention tested with `is not`). stone_stats
//  returns std::optional<StoneStats> (None below 12 on-board stones -> nullopt).
//
//  Determinism (rule 12): detect_board seeds cv::setRNGSeed(1234) exactly ONCE,
//  at detect.py:929 (just before the stone-lattice proposer). Nothing before it
//  consumes the global RNG (the proposer/rescue fits use findHomography method 0;
//  HoughLinesP uses OpenCV's own local RNG). recognize_image (Task 9) seeds once
//  at entry; do NOT add extra seeds here.
//
//  #pragma STDC FP_CONTRACT OFF + the target's -ffp-contract=off (numpy does not
//  fuse element-wise multiply-adds).
//

#include "gr_detect.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <functional>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>  // getPerspectiveTransform (OpenCV 5 header)
#include <opencv2/imgproc.hpp>   // warpPerspective/morphologyEx/filter2D/distanceTransform/findHomography

#include "gr_constants.h"
#include "gr_detect_internal.h"
#include "gr_grid.h"
#include "gr_parity.h"
#include "gr_stonelattice.h"

#pragma STDC FP_CONTRACT OFF

namespace gobanrecog {

namespace {

// ---- small linear-algebra helpers (numpy-order 3x3 math) -------------------

// 3x3 matmul in numpy's left-to-right dot order (a0*b0 + a1*b1) + a2*b2 —
// venv-verified bit-identical to numpy `@` on 3x3 inputs (Task 5/6 precedent).
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

cv::Mat toMat33(const cv::Matx33d& m) {
    cv::Mat r(3, 3, CV_64F);
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) r.at<double>(i, j) = m(i, j);
    return r;
}

// Perspective map of a single point through a 3x3 (numpy `H @ [x,y,1]`, then the
// homogeneous divide q[:2]/q[2]). The third column term is H(_,2)*1.0 = H(_,2).
inline cv::Point2d applyH(const cv::Matx33d& H, double x, double y) {
    const double wx = (H(0, 0) * x + H(0, 1) * y) + H(0, 2);
    const double wy = (H(1, 0) * x + H(1, 1) * y) + H(1, 2);
    const double ww = (H(2, 0) * x + H(2, 1) * y) + H(2, 2);
    return cv::Point2d(wx / ww, wy / ww);
}

// Python str(float): the SHORTEST round-tripping repr (matches CPython's float
// repr), used only to reproduce the "ambiguous board size" reason string's
// `scores` dict verbatim. std::to_chars gives the same shortest digits; CPython
// additionally appends ".0" to integer-valued floats (str(100.0) == "100.0").
std::string py_float_repr(double v) {
    if (std::isnan(v)) return "nan";
    if (std::isinf(v)) return v > 0 ? "inf" : "-inf";
    char buf[64];
    const std::to_chars_result r = std::to_chars(buf, buf + sizeof(buf), v);
    std::string s(buf, r.ptr);
    // CPython shows a decimal point or exponent; to_chars prints "100" for 100.0.
    if (s.find('.') == std::string::npos && s.find('e') == std::string::npos &&
        s.find('n') == std::string::npos && s.find('i') == std::string::npos)
        s += ".0";
    return s;
}

// ports detect.py::_corners_of. Perspective-maps the (n-1)-square's four corners
// through H (TL,TR,BR,BL). Returns a 4x2 CV_64F, matching detect.py's `corners`.
cv::Mat _corners_of(const cv::Matx33d& H, int n) {
    const double m = static_cast<double>(n - 1);
    const double cg[4][2] = {{0.0, 0.0}, {m, 0.0}, {m, m}, {0.0, m}};
    cv::Mat out(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        const cv::Point2d p = applyH(H, cg[k][0], cg[k][1]);
        out.at<double>(k, 0) = p.x;
        out.at<double>(k, 1) = p.y;
    }
    return out;
}

// ---- the fitted-candidate bundle (returned by _fit_lattice) ----------------

struct FitResult {
    SizeResult size_res;
    cv::Mat H_grid;   // CV_64F 3x3
    cv::Mat corners;  // 4x2 CV_64F
    cv::Mat rect;     // uint8 rectified frame (choose_size / cut-score input)
    cv::Mat H_rect;   // CV_64F 3x3 image->canonical warp
};

// ---- _extension_counts / _try_extension ------------------------------------

// ports detect.py::_extension_counts. `prof` is a float32 line profile.
std::pair<int, int> _extension_counts(const cv::Mat& prof, double o, double s, int n) {
    const int len = prof.cols;  // prof is a 1 x len CV_32F row
    const float* pf = prof.ptr<float>(0);

    // idx = clip(round(o + s*arange(n)).astype(int), 0, len-1); ref =
    // prof[idx].mean() + 1e-9  (FLOAT32: mean of f32 selection stays f32).
    std::vector<float> sel;
    sel.reserve(n);
    for (int i = 0; i < n; ++i) {
        int ip = static_cast<int>(np_round(o + s * static_cast<double>(i)));
        if (ip < 0) ip = 0;
        if (ip > len - 1) ip = len - 1;
        sel.push_back(pf[ip]);
    }
    const float ref = np_mean(sel.data(), sel.size()) + 1e-9f;

    // w = max(2, int(round(0.10 * s)))
    const int w = std::max(2, static_cast<int>(np_round(0.10 * s)));

    // walk(start, step): count lattice-spaced ridge continuations (<=8).
    const auto walk = [&](double start, double step) -> int {
        int c = 0;
        double p = start;
        for (int t = 0; t < 8; ++t) {
            p += step;
            const int ip = static_cast<int>(np_round(p));
            if (ip < w + 1 || ip > len - w - 2) break;
            // prof[ip-w:ip+w+1].max() > 0.55 * ref  (all float32)
            float mx = pf[ip - w];
            for (int k = ip - w + 1; k <= ip + w; ++k)
                if (pf[k] > mx) mx = pf[k];
            if (mx > 0.55f * ref)
                ++c;
            else
                break;
        }
        return c;
    };

    return {walk(o, -s), walk(o + (n - 1) * s, s)};
}

// forward decl (mutual use: _try_extension needs H_rect, produced by _fit_lattice)
FitResult _fit_lattice(const cv::Mat& gray, const cv::Mat& quad);

// ports detect.py::_try_extension. Returns the extended quad (4x2 CV_64F, image
// coords) or nullopt when the lattice does not continue onto a larger legal size.
std::optional<cv::Mat> _try_extension(const cv::Mat& rect, const SizeResult& size_res,
                                      const cv::Mat& H_rect) {
    const std::pair<cv::Mat, cv::Mat> profs = line_profiles(rect, RECT_PAD, SPAN, false);
    const cv::Mat& full_x = profs.first;
    const cv::Mat& full_y = profs.second;
    const int n = size_res.board_size;
    const std::vector<double>& xs = size_res.xs;
    const std::vector<double>& ys = size_res.ys;
    const double sx = (xs[n - 1] - xs[0]) / (n - 1);
    const double sy = (ys[n - 1] - ys[0]) / (n - 1);
    const std::pair<int, int> ex = _extension_counts(full_x, xs[0], sx, n);
    const std::pair<int, int> ey = _extension_counts(full_y, ys[0], sy, n);
    const int lx = ex.first, hx = ex.second;
    const int ly = ey.first, hy = ey.second;
    const int nx = n + lx + hx, ny = n + ly + hy;
    if (nx != ny || nx == n || (nx != 9 && nx != 13 && nx != 19)) return std::nullopt;
    const double x0 = xs[0] - lx * sx, x1 = xs[0] + (n - 1 + hx) * sx;
    const double y0 = ys[0] - ly * sy, y1 = ys[0] + (n - 1 + hy) * sy;
    // quad_canon = [[x0,y0],[x1,y0],[x1,y1],[x0,y1]] mapped by inv(H_rect)
    const cv::Matx33d Hri = toMatx33(inv3x3(H_rect));  // np.linalg.inv(H_rect)
    const double qc[4][2] = {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}};
    cv::Mat q(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        const cv::Point2d p = applyH(Hri, qc[k][0], qc[k][1]);
        q.at<double>(k, 0) = p.x;
        q.at<double>(k, 1) = p.y;
    }
    return q;
}

// ports detect.py::_fit_lattice. Rectify on `quad`, run choose_size, fit H_grid
// to the detected lattice. Throws DetectionError("homography fit failed") like
// Python's `if H_grid is None`.
FitResult _fit_lattice(const cv::Mat& gray, const cv::Mat& quad) {
    const std::pair<cv::Mat, cv::Mat> rq = rectify_quad(gray, quad);
    const cv::Mat& rect = rq.first;
    const cv::Mat& H_rect = rq.second;
    const SizeResult size_res = choose_size(rect);
    const int n = size_res.board_size;

    // grid_pts = [[c,r] for r in range(n) for c in range(n)]; canon_pts =
    // [[xs[c], ys[r]] ...]; img_pts = (inv(H_rect) @ [canon_pts,1].T).T[:,:2]/w
    const cv::Matx33d Hri = toMatx33(inv3x3(H_rect));
    std::vector<cv::Point2d> grid_pts;
    std::vector<cv::Point2d> img_pts;
    grid_pts.reserve(static_cast<size_t>(n) * n);
    img_pts.reserve(static_cast<size_t>(n) * n);
    for (int r = 0; r < n; ++r)
        for (int c = 0; c < n; ++c) {
            grid_pts.emplace_back(static_cast<double>(c), static_cast<double>(r));
            img_pts.push_back(applyH(Hri, size_res.xs[c], size_res.ys[r]));
        }

    cv::Mat H_grid = cv::findHomography(grid_pts, img_pts, 0);
    if (H_grid.empty()) throw DetectionError("homography fit failed");
    const cv::Matx33d Hg = toMatx33(H_grid);
    const cv::Mat corners = _corners_of(Hg, n);
    return {size_res, H_grid, corners, rect, H_rect};
}

// ---- lattice_quality (the only quad-independent comparator) -----------------

// ports detect.py::lattice_quality. Quad-independent fit quality in a common
// canonical frame. spacing=32, pad=48 (the stone SP/PAD frame, NOT RECT_PAD).
double lattice_quality(const cv::Mat& gray, const cv::Mat& H_grid, int n) {
    const int spacing = SP, pad = PAD;
    const cv::Matx33d A(spacing, 0.0, pad, 0.0, spacing, pad, 0.0, 0.0, 1.0);
    const int side = 2 * pad + (n - 1) * spacing;
    const cv::Matx33d W = matmul3(A, toMatx33(inv3x3(H_grid)));  // A @ inv(H_grid)
    cv::Mat rect;
    cv::warpPerspective(gray, rect, toMat33(W), cv::Size(side, side));

    cv::Mat bh_v, bh_h;
    cv::morphologyEx(rect, bh_v, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(L, 1)));
    cv::morphologyEx(rect, bh_h, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(1, L)));
    const int lo = pad, hi = pad + (n - 1) * spacing;

    // norm_v/norm_h = mean(bh[lo:hi, lo:hi]) + 1e-9  (exact uint8 integer mean)
    std::int64_t sv = 0, sh = 0;
    for (int y = lo; y < hi; ++y) {
        const uchar* rv = bh_v.ptr<uchar>(y);
        const uchar* rh = bh_h.ptr<uchar>(y);
        for (int x = lo; x < hi; ++x) {
            sv += rv[x];
            sh += rh[x];
        }
    }
    const double cnt = static_cast<double>(hi - lo) * (hi - lo);
    const double norm_v = static_cast<double>(sv) / cnt + 1e-9;
    const double norm_h = static_cast<double>(sh) / cnt + 1e-9;

    // ks = pad + spacing*arange(n)
    std::vector<int> ks(n);
    for (int i = 0; i < n; ++i) ks[i] = pad + spacing * i;

    // line_v = bh_v[lo:hi, ks].mean(axis=0)/norm_v  (per-ks-column integer mean)
    // line_h = bh_h[ks, lo:hi].mean(axis=1)/norm_h  (per-ks-row integer mean)
    std::vector<double> line_v(n), line_h(n);
    const double denomRows = static_cast<double>(hi - lo);
    for (int j = 0; j < n; ++j) {
        std::int64_t s = 0;
        for (int y = lo; y < hi; ++y) s += bh_v.ptr<uchar>(y)[ks[j]];
        line_v[j] = (static_cast<double>(s) / denomRows) / norm_v;
    }
    for (int i = 0; i < n; ++i) {
        std::int64_t s = 0;
        const uchar* row = bh_h.ptr<uchar>(ks[i]);
        for (int x = lo; x < hi; ++x) s += row[x];
        line_h[i] = (static_cast<double>(s) / denomRows) / norm_h;
    }

    // stoneness = |rect.astype(f32) - median(rect[lo:hi,lo:hi])|  (FLOAT64), with
    // the outside-[lo,hi] border zeroed BEFORE filter2D.
    const double med = np_median(rect(cv::Range(lo, hi), cv::Range(lo, hi)));
    cv::Mat stoneness(rect.rows, rect.cols, CV_64F);
    for (int y = 0; y < rect.rows; ++y) {
        const uchar* rr = rect.ptr<uchar>(y);
        double* sr = stoneness.ptr<double>(y);
        for (int x = 0; x < rect.cols; ++x)
            sr[x] = std::fabs(static_cast<double>(rr[x]) - med);
    }
    for (int y = 0; y < rect.rows; ++y) {
        double* sr = stoneness.ptr<double>(y);
        if (y < lo || y > hi) {  // stoneness[:lo]=0 ; stoneness[hi+1:]=0
            for (int x = 0; x < rect.cols; ++x) sr[x] = 0.0;
            continue;
        }
        for (int x = 0; x < lo; ++x) sr[x] = 0.0;            // stoneness[:, :lo]=0
        for (int x = hi + 1; x < rect.cols; ++x) sr[x] = 0.0;  // stoneness[:, hi+1:]=0
    }

    cv::Mat avg;
    cv::filter2D(stoneness, avg, -1, stoneKernel());  // _KER (17x17, normalized f32)

    // nodes = avg[ks, ks]; cells = avg[kc, kc]; kc = (pad + spacing*(arange(n-1)+0.5)).astype(int)
    std::vector<int> kc(n - 1);
    for (int i = 0; i < n - 1; ++i)
        kc[i] = static_cast<int>(static_cast<double>(pad) + spacing * (i + 0.5));

    std::vector<double> nodesFlat(static_cast<size_t>(n) * n);
    for (int i = 0; i < n; ++i)
        for (int j = 0; j < n; ++j)
            nodesFlat[static_cast<size_t>(i) * n + j] = avg.at<double>(ks[i], ks[j]);
    std::vector<double> cellsFlat(static_cast<size_t>(n - 1) * (n - 1));
    for (int i = 0; i < n - 1; ++i)
        for (int j = 0; j < n - 1; ++j)
            cellsFlat[static_cast<size_t>(i) * (n - 1) + j] = avg.at<double>(kc[i], kc[j]);

    const double scale =
        np_percentile(std::vector<double>(  // stoneness[lo:hi, lo:hi]
                          [&] {
                              std::vector<double> v;
                              v.reserve(static_cast<size_t>(hi - lo) * (hi - lo));
                              for (int y = lo; y < hi; ++y) {
                                  const double* sr = stoneness.ptr<double>(y);
                                  v.insert(v.end(), sr + lo, sr + hi);
                              }
                              return v;
                          }()),
                      95.0) +
        1e-6;

    // stone = (nodes.mean() - cells.mean()) / scale  (whole-array pairwise means)
    const double nodesMean = np_mean(nodesFlat.data(), nodesFlat.size());
    const double cellsMean = np_mean(cellsFlat.data(), cellsFlat.size());
    const double stone = (nodesMean - cellsMean) / scale;

    // stone_v = nodes.mean(axis=0)/scale (NAIVE column sums); stone_h =
    // nodes.mean(axis=1)/scale (PAIRWISE row sums)
    std::vector<double> stone_v(n), stone_h(n);
    for (int j = 0; j < n; ++j) {
        double s = 0.0;  // axis=0 naive down rows
        for (int i = 0; i < n; ++i) s += nodesFlat[static_cast<size_t>(i) * n + j];
        stone_v[j] = (s / n) / scale;
    }
    for (int i = 0; i < n; ++i) {
        const double s = np_pairwise_sum(&nodesFlat[static_cast<size_t>(i) * n], n);
        stone_h[i] = (s / n) / scale;
    }

    // weak = sum(line_v<0.8 & stone_v<0.12) + sum(line_h<0.8 & stone_h<0.12)
    int weak = 0;
    for (int j = 0; j < n; ++j)
        if (line_v[j] < 0.8 && stone_v[j] < 0.12) ++weak;
    for (int i = 0; i < n; ++i)
        if (line_h[i] < 0.8 && stone_h[i] < 0.12) ++weak;

    const double lvMean = np_mean(line_v.data(), line_v.size());
    const double lhMean = np_mean(line_h.data(), line_h.size());
    return (lvMean + lhMean) + 12.0 * stone - 1.2 * weak;
}

// ---- _spacing_anisotropy ---------------------------------------------------

// ports detect.py::_spacing_anisotropy. Ratio of implied image-pixel cell
// spacing between the two grid axes at board center.
double _spacing_anisotropy(const cv::Mat& H_grid, int n) {
    const cv::Matx33d H = toMatx33(H_grid);
    const double c = (n - 1) / 2.0;
    const cv::Point2d q0 = applyH(H, c - 0.5, c);
    const cv::Point2d q1 = applyH(H, c + 0.5, c);
    const cv::Point2d q2 = applyH(H, c, c - 0.5);
    const cv::Point2d q3 = applyH(H, c, c + 0.5);
    const double dx = std::sqrt((q1.x - q0.x) * (q1.x - q0.x) + (q1.y - q0.y) * (q1.y - q0.y));
    const double dy = std::sqrt((q3.x - q2.x) * (q3.x - q2.x) + (q3.y - q2.y) * (q3.y - q2.y));
    const double lo = std::min(dx, dy), hi = std::max(dx, dy);
    return hi / (lo + 1e-9);
}

// ---- _cut_score ------------------------------------------------------------

// ports detect.py::_cut_score. rect is the uint8 rectified frame; PAD/SPAN are
// grid's RECT_PAD=150 / SPAN=800 (detect.py imports them from grid).
double _cut_score(const cv::Mat& rect, const SizeResult& size_res) {
    // f = rect (uint8 in the pipeline; the clip-to-uint8 branch is dead).
    cv::Mat f;
    if (rect.type() == CV_8U) {
        f = rect;
    } else {
        cv::Mat d;
        rect.convertTo(d, CV_64F);
        f.create(rect.rows, rect.cols, CV_8U);
        for (int y = 0; y < rect.rows; ++y) {
            const double* s = d.ptr<double>(y);
            uchar* o = f.ptr<uchar>(y);
            for (int x = 0; x < rect.cols; ++x) {
                double v = s[x];
                if (v < 0.0) v = 0.0;
                if (v > 255.0) v = 255.0;
                o[x] = static_cast<uchar>(v);
            }
        }
    }
    cv::Mat bh_v, bh_h;
    cv::morphologyEx(f, bh_v, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(L, 1)));
    cv::morphologyEx(f, bh_h, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(1, L)));
    const std::pair<cv::Mat, cv::Mat> profs = line_profiles(rect, RECT_PAD, SPAN, false);
    const cv::Mat& full_x = profs.first;
    const cv::Mat& full_y = profs.second;

    // xs = clip(round(size_res.xs), 0, cols-1); ys likewise
    std::vector<int> xs(size_res.xs.size()), ys(size_res.ys.size());
    for (size_t i = 0; i < xs.size(); ++i) {
        int v = static_cast<int>(np_round(size_res.xs[i]));
        xs[i] = std::min(std::max(v, 0), rect.cols - 1);
    }
    for (size_t i = 0; i < ys.size(); ++i) {
        int v = static_cast<int>(np_round(size_res.ys[i]));
        ys[i] = std::min(std::max(v, 0), rect.rows - 1);
    }
    const int lo_b0 = 20, lo_b1 = RECT_PAD - 12;                    // slice(20, PAD-12)
    const int hi_b0 = RECT_PAD + SPAN + 12, hi_b1 = rect.rows - 20;  // slice(PAD+SPAN+12, rows-20)
    const int in0 = RECT_PAD + 15, in1 = RECT_PAD + SPAN - 15;       // slice(PAD+15, PAD+SPAN-15)

    // refx/refy = percentile(full[inner], 90) + 1e-9  (FLOAT32 percentile)
    const auto profPct = [&](const cv::Mat& prof) {
        std::vector<float> v;
        const float* p = prof.ptr<float>(0);
        v.assign(p + in0, p + in1);
        return static_cast<double>(np_percentile(v, 90.0)) + 1e-9;
    };
    const double refx = profPct(full_x);
    const double refy = profPct(full_y);

    // cin_h = mean(bh_h[ys][:,inner]) + 1e-9 ; cin_v = mean(bh_v[:,xs][inner,:]) + 1e-9
    const auto meanRowsCols = [](const cv::Mat& bh, const std::vector<int>& rows, int c0,
                                 int c1) {
        std::int64_t s = 0;
        std::int64_t cnt = 0;
        for (int r : rows) {
            const uchar* row = bh.ptr<uchar>(r);
            for (int x = c0; x < c1; ++x) s += row[x];
            cnt += (c1 - c0);
        }
        return static_cast<double>(s) / static_cast<double>(cnt);
    };
    const auto meanColsRows = [](const cv::Mat& bh, const std::vector<int>& cols, int r0,
                                 int r1) {
        std::int64_t s = 0;
        std::int64_t cnt = 0;
        for (int y = r0; y < r1; ++y) {
            const uchar* row = bh.ptr<uchar>(y);
            for (int c : cols) s += row[c];
            cnt += static_cast<std::int64_t>(cols.size());
        }
        return static_cast<double>(s) / static_cast<double>(cnt);
    };
    const double cin_h = meanRowsCols(bh_h, ys, in0, in1) + 1e-9;
    const double cin_v = meanColsRows(bh_v, xs, in0, in1) + 1e-9;

    // profile-window max, float32 then promote via float(...) exactly.
    const auto profMax = [](const cv::Mat& prof, int a, int b) {
        const float* p = prof.ptr<float>(0);
        float mx = p[a];
        for (int i = a + 1; i < b; ++i)
            if (p[i] > mx) mx = p[i];
        return static_cast<double>(mx);
    };

    const double edges[4][2] = {
        {profMax(full_x, lo_b0, lo_b1) / refx, meanRowsCols(bh_h, ys, lo_b0, lo_b1) / cin_h},
        {profMax(full_x, hi_b0, hi_b1) / refx, meanRowsCols(bh_h, ys, hi_b0, hi_b1) / cin_h},
        {profMax(full_y, lo_b0, lo_b1) / refy, meanColsRows(bh_v, xs, lo_b0, lo_b1) / cin_v},
        {profMax(full_y, hi_b0, hi_b1) / refy, meanColsRows(bh_v, xs, hi_b0, hi_b1) / cin_v},
    };
    double best = 0.0;  // max((ridge for ridge, cross in edges if ridge>1 and cross>0.25), default=0.0)
    for (const auto& e : edges) {
        const double ridge = e[0], cross = e[1];
        if (ridge > 1.0 && cross > 0.25 && ridge > best) best = ridge;
    }
    return best;
}

// ---- slab consistency ------------------------------------------------------

// ports detect.py::_slab_edge_scores. Per-edge (top,bottom,left,right) fraction
// of probe points 0.25 grid-spacings BEYOND that outer lattice line on slab wood.
cv::Vec4d _slab_edge_scores(const cv::Mat& mask, const cv::Mat& H_grid, int n) {
    const double m = static_cast<double>(n - 1);
    // ts = linspace(0, m, 25): ts[i] = i*(m/24), ts[24] = m (endpoint forced)
    std::vector<double> ts(25);
    const double step = m / 24.0;
    for (int i = 0; i < 25; ++i) ts[i] = i * step;
    ts[24] = m;
    const cv::Matx33d H = toMatx33(H_grid);
    const int h = mask.rows, w = mask.cols;
    cv::Vec4d out;
    for (int edge = 0; edge < 4; ++edge) {
        double sum = 0.0;
        for (int i = 0; i < 25; ++i) {
            double a, b;  // the (grid col,row) probe point for this edge
            if (edge == 0) { a = ts[i]; b = -0.25; }
            else if (edge == 1) { a = ts[i]; b = m + 0.25; }
            else if (edge == 2) { a = -0.25; b = ts[i]; }
            else { a = m + 0.25; b = ts[i]; }
            const cv::Point2d p = applyH(H, a, b);
            const bool inside = (p.x >= 0) && (p.x < w) && (p.y >= 0) && (p.y < h);
            double val = 0.0;
            if (inside) {
                int xi = static_cast<int>(np_round(p.x));
                int yi = static_cast<int>(np_round(p.y));
                if (xi < 0) xi = 0; if (xi > w - 1) xi = w - 1;
                if (yi < 0) yi = 0; if (yi > h - 1) yi = h - 1;
                val = static_cast<double>(mask.at<uchar>(yi, xi));
            }
            sum += val;
        }
        out[edge] = sum / 25.0;  // vals.mean() over the 25 probes
    }
    return out;
}

// ports detect.py::_slab_consistency. Mean of the four edge scores.
double _slab_consistency(const cv::Mat& mask, const cv::Mat& H_grid, int n) {
    const cv::Vec4d e = _slab_edge_scores(mask, H_grid, n);
    const double v[4] = {e[0], e[1], e[2], e[3]};
    return np_mean(v, 4);  // np.array(out).mean() (naive n<8)
}

// ---- stone maps & peaks ----------------------------------------------------

struct StoneMapResult {
    cv::Mat avg;    // CV_64F
    double scale;
    cv::Mat W;      // CV_64F 3x3
    int lo;
    int hi;
};

// ports detect.py::_stone_map. Canonical warp around lattice H + disk-averaged
// stoneness + scale (margin default 2).
StoneMapResult _stone_map(const cv::Mat& gray, const cv::Mat& H, int n, int margin) {
    const int side = 2 * PAD + (n - 1) * SP;
    const cv::Matx33d A(SP, 0.0, PAD + margin * SP, 0.0, SP, PAD + margin * SP, 0.0, 0.0, 1.0);
    const int big = side + 2 * margin * SP;
    const cv::Matx33d W = matmul3(A, toMatx33(inv3x3(H)));  // A @ inv(H)
    cv::Mat rect;
    cv::warpPerspective(gray, rect, toMat33(W), cv::Size(big, big));
    const int lo = PAD + margin * SP;
    const int hi = lo + (n - 1) * SP;
    const double med = np_median(rect(cv::Range(lo, hi), cv::Range(lo, hi)));
    cv::Mat stoneness(rect.rows, rect.cols, CV_64F);
    for (int y = 0; y < rect.rows; ++y) {
        const uchar* rr = rect.ptr<uchar>(y);
        double* sr = stoneness.ptr<double>(y);
        for (int x = 0; x < rect.cols; ++x)
            sr[x] = std::fabs(static_cast<double>(rr[x]) - med);
    }
    cv::Mat avg;
    cv::filter2D(stoneness, avg, -1, stoneKernel());
    std::vector<double> interior;
    interior.reserve(static_cast<size_t>(hi - lo) * (hi - lo));
    for (int y = lo; y < hi; ++y) {
        const double* sr = stoneness.ptr<double>(y);
        interior.insert(interior.end(), sr + lo, sr + hi);
    }
    const double scale = np_percentile(interior, 95.0) + 1e-6;
    return {avg, scale, toMat33(W), lo, hi};
}

// ports detect.py::_stone_peaks. Compact local maxima of the stoneness map =
// stone centers; a 4-direction MEAN-falloff compactness gate (distinct from
// stonelattice's 8-direction MIN-falloff _peaks_ring). Returns full-res points.
std::vector<cv::Point2d> _stone_peaks(const cv::Mat& avg, double thr, int min_sep) {
    cv::Mat small;
    cv::resize(avg, small, cv::Size(avg.cols / 2, avg.rows / 2), 0, 0, cv::INTER_AREA);
    const int sep = std::max(2, min_sep / 2);
    cv::Mat dil;
    cv::dilate(small, dil,
               cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * sep + 1, 2 * sep + 1)));
    // ys, xs = np.where((small >= dil) & (small > thr))  [row-major]
    struct Cand { double val; int x; int y; };
    std::vector<Cand> cands;
    const int h = small.rows, w = small.cols;
    for (int y = 0; y < h; ++y) {
        const double* sr = small.ptr<double>(y);
        const double* dr = dil.ptr<double>(y);
        for (int x = 0; x < w; ++x)
            if (sr[x] >= dr[x] && sr[x] > thr) cands.push_back({sr[x], x, y});
    }
    if (cands.empty()) return {};
    // order = np.argsort(-vals)[:600]  (descending; ties -> stable/row-major, rule 7)
    std::vector<int> order(cands.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int>(i);
    std::stable_sort(order.begin(), order.end(),
                     [&](int a, int b) { return nanLastDescending(cands[a].val, cands[b].val); });
    if (order.size() > 600) order.resize(600);

    const int half = SP / 4;  // 8
    const int dirs[4][2] = {{half, 0}, {-half, 0}, {0, half}, {0, -half}};
    std::vector<cv::Point2d> kept;
    for (int oi : order) {
        const cv::Point2d p(cands[oi].x, cands[oi].y);
        bool tooClose = false;
        for (const cv::Point2d& q : kept)
            if (std::hypot(p.x - q.x, p.y - q.y) < sep) { tooClose = true; break; }
        if (tooClose) continue;
        const int x = static_cast<int>(p.x), y = static_cast<int>(p.y);
        std::vector<double> ring;
        for (const auto& d : dirs) {
            const int dx = d[0], dy = d[1];
            if (x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h)
                ring.push_back(small.at<double>(y + dy, x + dx));
        }
        if (ring.empty()) continue;
        const double rmean = np_mean(ring.data(), ring.size());  // np.mean(ring)
        if (1.0 - rmean / (small.at<double>(y, x) + 1e-6) < 0.30) continue;
        kept.push_back(p);
    }
    std::vector<cv::Point2d> out;
    out.reserve(kept.size());
    for (const cv::Point2d& p : kept) out.emplace_back(2.0 * p.x, 2.0 * p.y);
    return out;
}

// ports detect.py::stone_stats. Lattice-independent stone centers checked against
// the fitted lattice. Returns nullopt below 12 on-board stones.
std::optional<StoneStats> stone_stats(const cv::Mat& gray, const cv::Mat& H, int n) {
    const StoneMapResult sm = _stone_map(gray, H, n, 2);
    const double thr = std::max(0.45 * sm.scale, 40.0);
    const int min_sep = static_cast<int>(0.6 * SP);
    const std::vector<cv::Point2d> pts = _stone_peaks(sm.avg, thr, min_sep);
    if (pts.empty()) return std::nullopt;

    const double loD = static_cast<double>(sm.lo);
    const size_t N = pts.size();
    std::vector<double> gx(N), gy(N), dist(N);
    std::vector<char> inb(N);
    int n_in = 0;
    for (size_t i = 0; i < N; ++i) {
        gx[i] = (pts[i].x - loD) / SP;                      // g = (pts - [lo,lo])/_SP
        gy[i] = (pts[i].y - loD) / SP;
        const double sx = np_round(gx[i]), sy = np_round(gy[i]);  // snapped
        const double dgx = gx[i] - sx, dgy = gy[i] - sy;
        dist[i] = std::sqrt(dgx * dgx + dgy * dgy);         // norm(axis=1) = sqrt
        const bool in = (gx[i] > -0.3) && (gx[i] < n - 0.7) && (gy[i] > -0.3) && (gy[i] < n - 0.7);
        inb[i] = in ? 1 : 0;
        if (in) ++n_in;
    }
    if (n_in < 12) return std::nullopt;

    // A = mean over in-board points of (dist > 0.30)
    int aCount = 0;
    for (size_t i = 0; i < N; ++i)
        if (inb[i] && dist[i] > 0.30) ++aCount;
    const double A = static_cast<double>(aCount) / static_cast<double>(n_in);

    // matched = inb & dist<=0.30 ; resid = median(dist[matched]) or 1.0
    std::vector<double> matchedDist;
    for (size_t i = 0; i < N; ++i)
        if (inb[i] && dist[i] <= 0.30) matchedDist.push_back(dist[i]);
    const double resid = matchedDist.empty() ? 1.0 : np_median(matchedDist);

    // out = ~inb & (-1.3 < g < n+0.3) ; B = sum(out & dist<=0.25)
    int B = 0;
    for (size_t i = 0; i < N; ++i) {
        if (inb[i]) continue;
        const bool out = (gx[i] > -1.3) && (gx[i] < n + 0.3) && (gy[i] > -1.3) && (gy[i] < n + 0.3);
        if (out && dist[i] <= 0.25) ++B;
    }
    return StoneStats{n_in, A, static_cast<double>(B), resid};
}

// ports detect.py::stone_anchor_refit. Iterative re-anchor + refit. Returns
// refined H or nullopt.
std::optional<cv::Mat> stone_anchor_refit(const cv::Mat& gray, const cv::Mat& H_grid, int n,
                                          int iters = 3) {
    const int win = 14;
    cv::Mat H = H_grid.clone();
    for (int it = 0; it < iters; ++it) {
        const StoneMapResult sm = _stone_map(gray, H, n, 0);  // margin=0
        const double thr = std::max(0.40 * sm.scale, 35.0);
        std::vector<int> ks(n);
        for (int i = 0; i < n; ++i) ks[i] = sm.lo + SP * i;  // lo + _SP*arange(n)
        std::vector<cv::Point2d> anchors, grid_pts;
        for (int iy = 0; iy < n; ++iy) {
            const int cy = ks[iy];
            for (int ix = 0; ix < n; ++ix) {
                const int cx = ks[ix];
                const int x0 = cx - win, y0 = cy - win;
                // w = avg[y0:y0+2win+1, x0:x0+2win+1]; empty windows skipped
                const int ya = std::max(y0, 0), yb = std::min(y0 + 2 * win + 1, sm.avg.rows);
                const int xa = std::max(x0, 0), xb = std::min(x0 + 2 * win + 1, sm.avg.cols);
                if (ya >= yb || xa >= xb) continue;  // w.size == 0
                double best = -std::numeric_limits<double>::infinity();
                int bj = -1, bi = -1;
                // np.argmax over the FULL slice window in row-major order. Slice
                // bounds are the numpy start:stop clamped to the array (start>=0).
                for (int yy = ya; yy < yb; ++yy) {
                    const double* row = sm.avg.ptr<double>(yy);
                    for (int xx = xa; xx < xb; ++xx)
                        if (row[xx] > best) { best = row[xx]; bj = xx; bi = yy; }
                }
                if (best < thr) continue;
                anchors.emplace_back(static_cast<double>(bj), static_cast<double>(bi));
                grid_pts.emplace_back(static_cast<double>(ix), static_cast<double>(iy));
            }
        }
        if (static_cast<double>(anchors.size()) < std::max(8.0, 0.25 * n * n)) return std::nullopt;
        cv::Mat Hc = cv::findHomography(grid_pts, anchors, 0);
        if (Hc.empty()) return std::nullopt;
        // H = inv(W) @ Hc ; H /= H[2,2]
        const cv::Matx33d Hm = matmul3(toMatx33(inv3x3(sm.W)), toMatx33(Hc));
        cv::Mat Hn(3, 3, CV_64F);
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) Hn.at<double>(i, j) = Hm(i, j) / Hm(2, 2);
        H = Hn;
    }
    return H;
}

// ---- _measure_nodes / _refine_H_nodes --------------------------------------

// subpix parabolic interpolation on a float32 profile (all-f32 arithmetic).
inline double subpix(const float* prof, int len, int i) {
    if (i <= 0 || i >= len - 1) return 0.0;
    const float d = prof[i - 1] - 2.0f * prof[i] + prof[i + 1];
    if (std::fabs(d) < 1e-9f) return 0.0;
    float v = 0.5f * (prof[i - 1] - prof[i + 1]) / d;
    if (v < -1.0f) v = -1.0f;
    if (v > 1.0f) v = 1.0f;
    return static_cast<double>(v);
}

// ports detect.py::_measure_nodes. Returns (src grid coords Nx2, image points
// Nx2) or nullopt below 16 measured nodes.
std::optional<std::pair<cv::Mat, cv::Mat>> _measure_nodes(const cv::Mat& gray,
                                                          const cv::Mat& H_grid, int n) {
    const int S = SP, P = PAD, r = R;
    const cv::Matx33d A(S, 0.0, P, 0.0, S, P, 0.0, 0.0, 1.0);
    const int side = 2 * P + (n - 1) * S;
    const cv::Matx33d WA = matmul3(A, toMatx33(inv3x3(H_grid)));  // A @ inv(H_grid)
    cv::Mat rect;
    cv::warpPerspective(gray, rect, toMat33(WA), cv::Size(side, side));

    cv::Mat bh_v, bh_h;
    cv::morphologyEx(rect, bh_v, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(L, 1)));
    cv::morphologyEx(rect, bh_h, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(1, L)));
    // cross = minimum(bh_v, bh_h).astype(f32)
    cv::Mat cross(rect.rows, rect.cols, CV_32F);
    for (int y = 0; y < rect.rows; ++y) {
        const uchar* v = bh_v.ptr<uchar>(y);
        const uchar* hh = bh_h.ptr<uchar>(y);
        float* cr = cross.ptr<float>(y);
        for (int x = 0; x < rect.cols; ++x) cr[x] = static_cast<float>(std::min(v[x], hh[x]));
    }
    const int lo = P, hi = P + (n - 1) * S;
    const double med = np_median(rect(cv::Range(lo, hi), cv::Range(lo, hi)));
    cv::Mat stoneness(rect.rows, rect.cols, CV_64F);
    for (int y = 0; y < rect.rows; ++y) {
        const uchar* rr = rect.ptr<uchar>(y);
        double* sr = stoneness.ptr<double>(y);
        for (int x = 0; x < rect.cols; ++x)
            sr[x] = std::fabs(static_cast<double>(rr[x]) - med);
    }
    std::vector<double> interior;
    interior.reserve(static_cast<size_t>(hi - lo) * (hi - lo));
    for (int y = lo; y < hi; ++y) {
        const double* sr = stoneness.ptr<double>(y);
        interior.insert(interior.end(), sr + lo, sr + hi);
    }
    const double stone_scale = np_percentile(interior, 95.0) + 1e-6;
    // binary = (stoneness > 0.5*stone_scale)  (float64 compare)
    cv::Mat binary(rect.rows, rect.cols, CV_8U);
    const double bthr = 0.5 * stone_scale;
    for (int y = 0; y < rect.rows; ++y) {
        const double* sr = stoneness.ptr<double>(y);
        uchar* br = binary.ptr<uchar>(y);
        for (int x = 0; x < rect.cols; ++x) br[x] = (sr[x] > bthr) ? 1 : 0;
    }
    cv::Mat dt;
    cv::distanceTransform(binary, dt, cv::DIST_L2, 5);  // CV_32F

    // node_max[row][col] = cross window max (float32); cref = percentile(node_max, 80) + 1e-6
    std::vector<float> node_max(static_cast<size_t>(n) * n);
    for (int row = 0; row < n; ++row)
        for (int col = 0; col < n; ++col) {
            const int cy = P + row * S, cx = P + col * S;
            float mx = -std::numeric_limits<float>::infinity();
            for (int yy = cy - r; yy <= cy + r; ++yy) {
                const float* cr = cross.ptr<float>(yy);
                for (int xx = cx - r; xx <= cx + r; ++xx)
                    if (cr[xx] > mx) mx = cr[xx];
            }
            node_max[static_cast<size_t>(row) * n + col] = mx;
        }
    const double cref = static_cast<double>(np_percentile(node_max, 80.0)) + 1e-6;
    const float nodeThr = static_cast<float>(std::max(0.35 * cref, 8.0));  // f32 compare gate

    std::vector<cv::Point2d> src, dst;
    for (int row = 0; row < n; ++row) {
        for (int col = 0; col < n; ++col) {
            const int x = P + col * S, y = P + row * S;
            // wc = cross[y-r:y+r+1, x-r:x+r+1]; wc.max(); argmax (row-major, first)
            const int wsz = 2 * r + 1;
            float wcmax = -std::numeric_limits<float>::infinity();
            int argj = 0, seen = 0;
            for (int dy = 0; dy < wsz; ++dy) {
                const float* cr = cross.ptr<float>(y - r + dy);
                for (int dx = 0; dx < wsz; ++dx) {
                    const float val = cr[x - r + dx];
                    if (val > wcmax) { wcmax = val; argj = seen; }
                    ++seen;
                }
            }
            if (wcmax > nodeThr) {  // visible crossing (float32 compare)
                const int dy0 = argj / wsz, dx0 = argj % wsz;
                const int px = x - r + dx0, py = y - r + dy0;
                // colprof = bh_v[py-3:py+4, x-r:x+r+1].astype(f32).sum(axis=0)  (len wsz)
                std::vector<float> colprof(wsz, 0.0f);
                for (int yy = py - 3; yy <= py + 3; ++yy) {
                    const uchar* rv = bh_v.ptr<uchar>(yy);
                    for (int k = 0; k < wsz; ++k) colprof[k] += rv[x - r + k];
                }
                // rowprof = bh_h[y-r:y+r+1, px-3:px+4].astype(f32).sum(axis=1)  (len wsz)
                std::vector<float> rowprof(wsz, 0.0f);
                for (int k = 0; k < wsz; ++k) {
                    const uchar* rh = bh_h.ptr<uchar>(y - r + k);
                    float s = 0.0f;
                    for (int xx = px - 3; xx <= px + 3; ++xx) s += rh[xx];
                    rowprof[k] = s;
                }
                int jx = 0, jy = 0;
                for (int k = 1; k < wsz; ++k) {
                    if (colprof[k] > colprof[jx]) jx = k;
                    if (rowprof[k] > rowprof[jy]) jy = k;
                }
                src.emplace_back(static_cast<double>(col), static_cast<double>(row));
                dst.emplace_back((x - r + jx) + subpix(colprof.data(), wsz, jx),
                                 (y - r + jy) + subpix(rowprof.data(), wsz, jy));
                continue;
            }
            // ws = dt[y-r:y+r+1, x-r:x+r+1]; ISOLATED stone if 0.30*S < ws.max() < 0.55*S
            float wsmax = -std::numeric_limits<float>::infinity();
            for (int dy = 0; dy < wsz; ++dy) {
                const float* dr = dt.ptr<float>(y - r + dy);
                for (int dx = 0; dx < wsz; ++dx)
                    if (dr[x - r + dx] > wsmax) wsmax = dr[x - r + dx];
            }
            if (static_cast<float>(0.30 * S) < wsmax && wsmax < static_cast<float>(0.55 * S)) {
                double sumx = 0.0, sumy = 0.0;
                int cnt = 0;
                const float lim = wsmax - 1.0f;
                for (int dy = 0; dy < wsz; ++dy) {
                    const float* dr = dt.ptr<float>(y - r + dy);
                    for (int dx = 0; dx < wsz; ++dx)
                        if (dr[x - r + dx] >= lim) { sumx += dx; sumy += dy; ++cnt; }
                }
                src.emplace_back(static_cast<double>(col), static_cast<double>(row));
                dst.emplace_back((x - r) + sumx / cnt, (y - r) + sumy / cnt);
            }
        }
    }
    // dt_wood = distanceTransform(1 - binary); enclosed wood holes at cell centers
    cv::Mat invBinary(rect.rows, rect.cols, CV_8U);
    for (int y = 0; y < rect.rows; ++y) {
        const uchar* br = binary.ptr<uchar>(y);
        uchar* ir = invBinary.ptr<uchar>(y);
        for (int x = 0; x < rect.cols; ++x) ir[x] = static_cast<uchar>(1 - br[x]);
    }
    cv::Mat dt_wood;
    cv::distanceTransform(invBinary, dt_wood, cv::DIST_L2, 5);
    const int wsz = 2 * r + 1;
    for (int row = 0; row < n - 1; ++row) {
        for (int col = 0; col < n - 1; ++col) {
            const int x = static_cast<int>(np_round(P + (col + 0.5) * S));
            const int y = static_cast<int>(np_round(P + (row + 0.5) * S));
            float wfmax = -std::numeric_limits<float>::infinity();
            for (int dy = 0; dy < wsz; ++dy) {
                const float* dr = dt_wood.ptr<float>(y - r + dy);
                for (int dx = 0; dx < wsz; ++dx)
                    if (dr[x - r + dx] > wfmax) wfmax = dr[x - r + dx];
            }
            if (2.0f < wfmax && wfmax < static_cast<float>(0.35 * S)) {
                double sumx = 0.0, sumy = 0.0;
                int cnt = 0;
                const float lim = wfmax - 1.0f;
                for (int dy = 0; dy < wsz; ++dy) {
                    const float* dr = dt_wood.ptr<float>(y - r + dy);
                    for (int dx = 0; dx < wsz; ++dx)
                        if (dr[x - r + dx] >= lim) { sumx += dx; sumy += dy; ++cnt; }
                }
                src.emplace_back(col + 0.5, row + 0.5);
                dst.emplace_back((x - r) + sumx / cnt, (y - r) + sumy / cnt);
            }
        }
    }
    if (src.size() < 16) return std::nullopt;

    // q = (H_grid @ inv(A) @ [dst,1].T).T ; return (src, q[:,:2]/q[:,2])
    const cv::Matx33d M = matmul3(toMatx33(H_grid), toMatx33(inv3x3(toMat33(A))));
    cv::Mat srcMat(static_cast<int>(src.size()), 2, CV_64F);
    cv::Mat imgMat(static_cast<int>(src.size()), 2, CV_64F);
    for (size_t i = 0; i < src.size(); ++i) {
        srcMat.at<double>(static_cast<int>(i), 0) = src[i].x;
        srcMat.at<double>(static_cast<int>(i), 1) = src[i].y;
        const cv::Point2d p = applyH(M, dst[i].x, dst[i].y);
        imgMat.at<double>(static_cast<int>(i), 0) = p.x;
        imgMat.at<double>(static_cast<int>(i), 1) = p.y;
    }
    return std::make_pair(srcMat, imgMat);
}

// ports detect.py::_refine_H_nodes. Polish H against per-node measurements; keep
// the best-lattice_quality iterate. Returns nullopt (= keep H_grid) unless the
// refit clearly improves quality (>= q0 + QUALITY_GAIN), matching Python's
// `return H_grid` (unchanged object) vs `return best_H`.
std::optional<cv::Mat> _refine_H_nodes(const cv::Mat& gray, const cv::Mat& H_grid, int n,
                                       int iters = 6) {
    const double q0 = lattice_quality(gray, H_grid, n);
    cv::Mat best_H;  // None
    double best_q = -std::numeric_limits<double>::infinity();
    cv::Mat H = H_grid.clone();
    for (int it = 0; it < iters; ++it) {
        const std::optional<std::pair<cv::Mat, cv::Mat>> m = _measure_nodes(gray, H, n);
        if (!m) break;
        const cv::Mat& src = m->first;
        const cv::Mat& img_pts = m->second;
        double smin0 = src.at<double>(0, 0), smax0 = smin0;
        double smin1 = src.at<double>(0, 1), smax1 = smin1;
        for (int i = 0; i < src.rows; ++i) {
            const double a = src.at<double>(i, 0), b = src.at<double>(i, 1);
            smin0 = std::min(smin0, a); smax0 = std::max(smax0, a);
            smin1 = std::min(smin1, b); smax1 = std::max(smax1, b);
        }
        if (smax0 - smin0 < 0.6 * (n - 1) || smax1 - smin1 < 0.6 * (n - 1)) break;
        std::vector<cv::Point2d> srcP(src.rows), dstP(src.rows);
        for (int i = 0; i < src.rows; ++i) {
            srcP[i] = cv::Point2d(src.at<double>(i, 0), src.at<double>(i, 1));
            dstP[i] = cv::Point2d(img_pts.at<double>(i, 0), img_pts.at<double>(i, 1));
        }
        cv::Mat mask;
        cv::Mat Hn = cv::findHomography(srcP, dstP, cv::LMEDS, 3.0, mask);
        if (Hn.empty() || mask.empty() || cv::countNonZero(mask) < 12) break;
        const cv::Mat c_old = _corners_of(toMatx33(H), n);
        const cv::Mat c_new = _corners_of(toMatx33(Hn), n);
        const double diag = std::sqrt(
            std::pow(c_old.at<double>(2, 0) - c_old.at<double>(0, 0), 2) +
            std::pow(c_old.at<double>(2, 1) - c_old.at<double>(0, 1), 2));
        double moveMax = 0.0;
        for (int k = 0; k < 4; ++k) {
            const double mv = std::sqrt(
                std::pow(c_new.at<double>(k, 0) - c_old.at<double>(k, 0), 2) +
                std::pow(c_new.at<double>(k, 1) - c_old.at<double>(k, 1), 2));
            moveMax = std::max(moveMax, mv);
        }
        if (moveMax > 0.08 * diag) break;
        H = Hn;
        const double q = lattice_quality(gray, H, n);
        if (q > best_q) { best_H = H.clone(); best_q = q; }
    }
    if (best_H.empty() || best_q < q0 + QUALITY_GAIN) return std::nullopt;
    return best_H;
}

// ---- _shift_search ---------------------------------------------------------

// ports detect.py::_shift_search. Returns nullopt (= no better H found) or the
// improved H (Python's `best_H is not H_grid`).
std::optional<cv::Mat> _shift_search(const cv::Mat& gray, const cv::Mat& H_grid, int n,
                                     const cv::Mat& mask) {
    const double c_in = _slab_consistency(mask, H_grid, n);
    const auto score = [&](const cv::Mat& H) {
        return lattice_quality(gray, H, n) + SHIFT_BONUS_WEIGHT * _slab_consistency(mask, H, n);
    };
    cv::Mat best_H = H_grid;
    double best_s = score(H_grid);
    bool improved = false;
    for (int dr = -2; dr <= 2; ++dr) {
        for (int dc = -2; dc <= 2; ++dc) {
            if (dr == 0 && dc == 0) continue;
            const cv::Matx33d T(1.0, 0.0, static_cast<double>(dc), 0.0, 1.0,
                                static_cast<double>(dr), 0.0, 0.0, 1.0);
            for (int refit = 0; refit < 2; ++refit) {
                try {
                    cv::Mat H;
                    if (refit) {
                        const cv::Mat q = _corners_of(matmul3(toMatx33(H_grid), T), n);
                        const FitResult fr = _fit_lattice(gray, q);
                        if (fr.size_res.board_size != n) continue;
                        H = fr.H_grid;
                    } else {
                        H = toMat33(matmul3(toMatx33(H_grid), T));
                    }
                    const std::optional<cv::Mat> refined = _refine_H_nodes(gray, H, n, 2);
                    if (refined) H = *refined;
                    if (_slab_consistency(mask, H, n) < c_in + SHIFT_MIN_GAIN) continue;
                    const double s = score(H);
                    if (s > best_s + 1e-6) { best_H = H; best_s = s; improved = true; }
                } catch (const DetectionError&) {
                    continue;
                } catch (const cv::Exception&) {
                    continue;
                } catch (const LinAlgError&) {
                    continue;
                }
            }
        }
    }
    if (!improved) return std::nullopt;
    return best_H;
}

// ---- verification / margin helpers -----------------------------------------

// ports detect.py::_verified.
bool _verified(const std::optional<StoneStats>& st, int n) {
    return st.has_value() && st->n_in >= std::max(12.0, 0.25 * n * n) && st->A <= 0.10 &&
           st->B <= 1 && st->resid <= 0.23;
}

// ports detect.py::_nocont_margin. Best minus second-best hypothesis score.
double _nocont_margin(const SizeResult& size_res) {
    std::vector<double> vals;
    vals.reserve(size_res.scores.size());
    for (const auto& kv : size_res.scores) vals.push_back(kv.second);
    // Python: sorted(size_res.scores.values(), reverse=True) — a STABLE sort
    // (rule 7). nanLastDescending keeps it a valid strict-weak ordering if a
    // hypothesis score is NaN (numpy/Python would sort NaN last too).
    std::stable_sort(vals.begin(), vals.end(),
                     [](double a, double b) { return nanLastDescending(a, b); });
    return vals[0] - vals[1];
}

// ports detect.py::_eff_margin.
double _eff_margin(const SizeResult& size_res, const std::optional<StoneStats>& st) {
    return _verified(st, size_res.board_size) ? _nocont_margin(size_res) : size_res.margin;
}

// ---- the candidate bundle & the two remaining vetoes -----------------------

struct Candidate {
    SizeResult size_res;                 // c[0]
    cv::Mat H_grid;                      // c[1]
    cv::Mat corners;                     // c[2]
    std::string name;                    // c[3]
    double cut_score;                    // c[4]
    std::optional<StoneStats> stone_stats;  // c[5]
};

// ports detect.py::_is_subgrid. True if `small`'s lattice lands on integer grid
// coords of `large`'s lattice (small is a window into large's board).
bool _is_subgrid(const Candidate& small, const Candidate& large) {
    const int size_s = small.size_res.board_size;
    const int size_l = large.size_res.board_size;
    if (size_s >= size_l) return false;
    const cv::Matx33d Hs = toMatx33(small.H_grid);
    const cv::Matx33d Hli = toMatx33(inv3x3(large.H_grid));
    int total = 0, on = 0;
    for (int r = 0; r < size_s; ++r) {
        for (int c = 0; c < size_s; ++c) {
            // img = H_s @ [c,r,1] ; g = inv(H_l) @ img ; g2 = g[:2]/g[2]
            const double ix = (Hs(0, 0) * c + Hs(0, 1) * r) + Hs(0, 2);
            const double iy = (Hs(1, 0) * c + Hs(1, 1) * r) + Hs(1, 2);
            const double iw = (Hs(2, 0) * c + Hs(2, 1) * r) + Hs(2, 2);
            const double gx0 = (Hli(0, 0) * ix + Hli(0, 1) * iy) + Hli(0, 2) * iw;
            const double gy0 = (Hli(1, 0) * ix + Hli(1, 1) * iy) + Hli(1, 2) * iw;
            const double gw0 = (Hli(2, 0) * ix + Hli(2, 1) * iy) + Hli(2, 2) * iw;
            const double gx = gx0 / gw0, gy = gy0 / gw0;
            const double sx = np_round(gx), sy = np_round(gy);
            const bool near = std::max(std::fabs(gx - sx), std::fabs(gy - sy)) < 0.2;
            const bool lo_ok = (sx >= -0.01) && (sy >= -0.01);
            const bool hi_ok = (sx <= size_l - 0.99) && (sy <= size_l - 0.99);
            if (near && lo_ok && hi_ok) ++on;
            ++total;
        }
    }
    return (static_cast<double>(on) / total) > 0.8;  // on_lattice.mean() > 0.8
}

// ---- _stone_lattice_candidate_quads (last-resort proposer) -----------------

// ports detect.py::_stone_lattice_candidate_quads.
std::vector<cv::Mat> _stone_lattice_candidate_quads(const cv::Mat& gray,
                                                    const std::vector<Candidate>& candidates) {
    // seeds from the top-2 candidates by margin + an image-wide synthetic seed.
    std::vector<size_t> ranked(candidates.size());
    for (size_t i = 0; i < ranked.size(); ++i) ranked[i] = i;
    std::stable_sort(ranked.begin(), ranked.end(), [&](size_t a, size_t b) {  // key=-margin
        return nanLastDescending(candidates[a].size_res.margin, candidates[b].size_res.margin);
    });
    std::vector<std::pair<cv::Mat, int>> seeds;
    for (size_t k = 0; k < ranked.size() && k < 2; ++k)
        seeds.emplace_back(candidates[ranked[k]].H_grid, candidates[ranked[k]].size_res.board_size);

    const int h_i = gray.rows, w_i = gray.cols;
    const cv::Point2f rect_w[4] = {
        {static_cast<float>(0.15 * w_i), static_cast<float>(0.15 * h_i)},
        {static_cast<float>(0.85 * w_i), static_cast<float>(0.15 * h_i)},
        {static_cast<float>(0.85 * w_i), static_cast<float>(0.85 * h_i)},
        {static_cast<float>(0.15 * w_i), static_cast<float>(0.85 * h_i)}};
    const cv::Point2f src_w[4] = {{0, 0}, {12, 0}, {12, 12}, {0, 12}};
    cv::Mat seedM = cv::getPerspectiveTransform(src_w, rect_w);  // CV_64F
    seeds.emplace_back(seedM, 13);

    std::vector<cv::Mat> quads;
    std::vector<std::pair<cv::Mat, int>> depth_seeds = seeds;
    for (int depth = 0; depth < 3; ++depth) {
        std::vector<std::pair<cv::Mat, int>> nxt;
        for (size_t si = 0; si < depth_seeds.size() && si < 4; ++si) {
            const cv::Mat& H_s = depth_seeds[si].first;
            const int n_s = depth_seeds[si].second;
            std::vector<SlFit> fits;
            try {
                fits = sl_fits(gray, H_s, n_s);
            } catch (const cv::Exception&) {
                continue;
            } catch (const LinAlgError&) {
                continue;
            }
            for (const SlFit& f : fits) {
                const std::vector<cv::Mat> qs = quads_of(f.Hd, f.ext_cols, f.ext_rows);
                quads.insert(quads.end(), qs.begin(), qs.end());
                const bool clean = (f.ext_cols == f.ext_rows) &&
                                   (f.ext_cols == 9 || f.ext_cols == 13 || f.ext_cols == 19);
                if (clean) {
                    std::optional<StoneStats> st_d;
                    try {
                        st_d = stone_stats(gray, f.Hd, f.ext_cols);
                    } catch (const cv::Exception&) {
                        st_d = std::nullopt;
                    } catch (const LinAlgError&) {
                        st_d = std::nullopt;
                    }
                    const bool admit = st_d.has_value() && st_d->A <= 0.10 && st_d->B <= 1;
                    if (!admit) nxt.emplace_back(f.Hd, f.ext_cols);
                } else if (std::min(f.ext_cols, f.ext_rows) >= 3) {
                    int nx = std::max(f.ext_cols, f.ext_rows);
                    nx = std::min(std::max(nx, 4), 19);  // np.clip(max(ext), 4, 19)
                    nxt.emplace_back(f.Hd, nx);
                }
            }
        }
        depth_seeds = nxt;
        if (depth_seeds.empty()) break;
    }
    // uniq: drop quads within 3.0 (max abs elementwise) of a kept one; keep <=8
    std::vector<cv::Mat> uniq;
    for (const cv::Mat& q : quads) {
        bool dup = false;
        for (const cv::Mat& u : uniq) {
            double mx = 0.0;
            for (int k = 0; k < 4; ++k)
                for (int j = 0; j < 2; ++j)
                    mx = std::max(mx, std::fabs(q.at<double>(k, j) - u.at<double>(k, j)));
            if (mx < 3.0) { dup = true; break; }
        }
        if (!dup) uniq.push_back(q);
    }
    if (uniq.size() > 8) uniq.resize(8);
    return uniq;
}

}  // namespace

// ============================================================================
// detect_board (detect.py:859) — orchestration
// ============================================================================

BoardDetection detect_board(const cv::Mat& img_bgr, double min_size_margin) {
    cv::Mat gray;
    cv::cvtColor(img_bgr, gray, cv::COLOR_BGR2GRAY);
    const int hgt = gray.rows, wid = gray.cols;
    std::optional<cv::Mat> wood;
    try {
        wood = _wood_mask(img_bgr);
    } catch (const cv::Exception&) {
        wood = std::nullopt;
    }

    std::vector<Candidate> candidates;
    std::vector<std::string> errors;

    // add_candidate: reject pathological margins, attach cut_score + stone_stats.
    const auto add_candidate = [&](const SizeResult& size_res, const cv::Mat& H_grid,
                                   const cv::Mat& corners, const cv::Mat& rect,
                                   const std::string& name) -> std::optional<StoneStats> {
        if (!std::isfinite(size_res.margin) || std::fabs(size_res.margin) > 500.0)
            return std::nullopt;
        std::optional<StoneStats> st;
        try {
            st = stone_stats(gray, H_grid, size_res.board_size);
        } catch (const cv::Exception&) {
            st = std::nullopt;
        } catch (const LinAlgError&) {
            st = std::nullopt;
        }
        candidates.push_back({size_res, H_grid, corners, name, _cut_score(rect, size_res), st});
        return st;
    };

    // proposers = (("hull", hull2), ("hough", hough), ("hull1", hull1),
    //              ("texture", texture), ("slab", slab(bgr)))
    struct Proposer { const char* name; std::function<cv::Mat()> fn; };
    const std::vector<Proposer> proposers = {
        {"hull", [&] { return _quad_hull(gray, 2); }},
        {"hough", [&] { return _quad_hough(gray); }},
        {"hull1", [&] { return _quad_hull(gray, 1); }},
        {"texture", [&] { return _quad_texture(gray); }},
        {"slab", [&] { return _quad_slab(img_bgr); }},
    };
    for (const Proposer& pr : proposers) {
        try {
            const cv::Mat quad = pr.fn();
            const FitResult fr = _fit_lattice(gray, quad);
            add_candidate(fr.size_res, fr.H_grid, fr.corners, fr.rect, pr.name);
            const std::optional<cv::Mat> ext_quad =
                _try_extension(fr.rect, fr.size_res, fr.H_rect);
            if (ext_quad) {
                const FitResult fe = _fit_lattice(gray, *ext_quad);
                add_candidate(fe.size_res, fe.H_grid, fe.corners, fe.rect,
                              std::string(pr.name) + "+ext");
            }
        } catch (const DetectionError& e) {
            errors.push_back(std::string(pr.name) + ": " + e.what());
        } catch (const cv::Exception& e) {
            errors.push_back(std::string(pr.name) + ": " + e.what());
        } catch (const LinAlgError& e) {
            errors.push_back(std::string(pr.name) + ": " + e.what());
        }
    }

    // rescue: anchor-refit the best-margin stone-INCONSISTENT candidate.
    std::vector<size_t> rescuable;
    for (size_t i = 0; i < candidates.size(); ++i) {
        const std::optional<StoneStats>& st = candidates[i].stone_stats;
        if (st.has_value() && (st->A > 0.10 || st->B > 3)) rescuable.push_back(i);
    }
    std::stable_sort(rescuable.begin(), rescuable.end(), [&](size_t a, size_t b) {
        return nanLastDescending(candidates[a].size_res.margin, candidates[b].size_res.margin);
    });
    for (size_t ri = 0; ri < rescuable.size() && ri < 1; ++ri) {
        const Candidate& rc = candidates[rescuable[ri]];  // size_r,H_r,corners_r,src_r,_,_
        const int size_r = rc.size_res.board_size;
        const cv::Mat H_r = rc.H_grid;
        const std::string src_r = rc.name;
        try {
            const std::optional<cv::Mat> H_a = stone_anchor_refit(gray, H_r, size_r);
            if (!H_a) continue;
            const FitResult fa = _fit_lattice(gray, _corners_of(toMatx33(*H_a), size_r));
            const size_t n_before = candidates.size();
            const std::optional<StoneStats> st_a =
                add_candidate(fa.size_res, fa.H_grid, fa.corners, fa.rect, src_r + "+a");
            if (candidates.size() > n_before &&
                !(st_a.has_value() && st_a->A <= 0.10 && st_a->B <= 3))
                candidates.pop_back();
        } catch (const DetectionError&) {
        } catch (const cv::Exception&) {
        } catch (const LinAlgError&) {
        }
    }

    // stone-lattice proposer: only when no candidate is stone-verified.
    bool anyVerified = false;
    for (const Candidate& c : candidates)
        if (_verified(c.stone_stats, c.size_res.board_size)) { anyVerified = true; break; }
    if (!candidates.empty() && !anyVerified) {
        cv::setRNGSeed(1234);  // RANSAC determinism (detect.py:929; the ONLY seed)
        std::vector<cv::Mat> sl_quads;
        try {
            sl_quads = _stone_lattice_candidate_quads(gray, candidates);
        } catch (const cv::Exception&) {
            sl_quads.clear();
        } catch (const LinAlgError&) {
            sl_quads.clear();
        }
        for (const cv::Mat& q : sl_quads) {
            try {
                const FitResult fs = _fit_lattice(gray, q);
                const size_t n_before = candidates.size();
                const std::optional<StoneStats> st_s =
                    add_candidate(fs.size_res, fs.H_grid, fs.corners, fs.rect, "slat");
                if (candidates.size() > n_before &&
                    !(st_s.has_value() && st_s->A <= 0.10 && st_s->B <= 1))
                    candidates.pop_back();
            } catch (const DetectionError&) {
            } catch (const cv::Exception&) {
            } catch (const LinAlgError&) {
            }
        }
    }

    if (candidates.empty()) {
        std::string joined;
        for (size_t i = 0; i < errors.size(); ++i) {
            if (i) joined += "; ";
            joined += errors[i];
        }
        throw DetectionError("all quad proposers failed: " + joined);
    }

    // chimera veto: drop grossly-anisotropic fits (unless none survive).
    {
        std::vector<Candidate> iso;
        for (const Candidate& c : candidates)
            if (_spacing_anisotropy(c.H_grid, c.size_res.board_size) <= MAX_SPACING_ANISO)
                iso.push_back(c);
        if (!iso.empty()) candidates = iso;
    }

    // sub-grid veto: drop candidates that are windows of a larger candidate.
    {
        std::vector<Candidate> keep;
        for (size_t i = 0; i < candidates.size(); ++i) {
            bool isSub = false;
            for (size_t j = 0; j < candidates.size(); ++j) {
                if (j == i) continue;  // other is not c
                if (_is_subgrid(candidates[i], candidates[j])) { isSub = true; break; }
            }
            if (!isSub) keep.push_back(candidates[i]);
        }
        if (!keep.empty()) candidates = keep;
    }

    // cut veto: a grid-cutting quad loses to a non-cutting one (verified exempt).
    {
        std::vector<Candidate> keep;
        for (size_t i = 0; i < candidates.size(); ++i) {
            const Candidate& a = candidates[i];
            bool cutLose = false;
            if (a.cut_score > CUT_ABS) {
                for (size_t j = 0; j < candidates.size(); ++j) {
                    if (j == i) continue;  // b is not a
                    if (a.cut_score > CUT_REL_MULT * candidates[j].cut_score + CUT_REL_ADD) {
                        cutLose = true;
                        break;
                    }
                }
            }
            if (_verified(a.stone_stats, a.size_res.board_size) || !cutLose) keep.push_back(a);
        }
        if (!keep.empty()) candidates = keep;
    }

    // arbitration: max by _eff_margin (Python's max keeps the FIRST on ties).
    size_t best = 0;
    double bestKey = _eff_margin(candidates[0].size_res, candidates[0].stone_stats);
    for (size_t i = 1; i < candidates.size(); ++i) {
        const double key = _eff_margin(candidates[i].size_res, candidates[i].stone_stats);
        if (key > bestKey) { bestKey = key; best = i; }
    }
    SizeResult size_res = candidates[best].size_res;
    cv::Mat H_grid = candidates[best].H_grid;
    cv::Mat corners = candidates[best].corners;
    const std::string src = candidates[best].name;
    std::optional<StoneStats> st = candidates[best].stone_stats;

    // refinement: refit on the lattice EXPANDED by half a spacing; iterate.
    const double orig_margin = size_res.margin;
    const int n = size_res.board_size;
    const double diag = std::sqrt(
        std::pow(corners.at<double>(2, 0) - corners.at<double>(0, 0), 2) +
        std::pow(corners.at<double>(2, 1) - corners.at<double>(0, 1), 2));
    const double mm = static_cast<double>(n - 1);
    for (int it = 0; it < 3; ++it) {
        FitResult fr2;
        try {
            const double eg[4][2] = {{-0.5, -0.5}, {mm + 0.5, -0.5}, {mm + 0.5, mm + 0.5},
                                     {-0.5, mm + 0.5}};
            const cv::Matx33d Hg = toMatx33(H_grid);
            cv::Mat q(4, 2, CV_64F);
            for (int k = 0; k < 4; ++k) {
                const cv::Point2d p = applyH(Hg, eg[k][0], eg[k][1]);
                q.at<double>(k, 0) = p.x;
                q.at<double>(k, 1) = p.y;
            }
            fr2 = _fit_lattice(gray, q);
        } catch (const DetectionError&) {
            break;
        } catch (const cv::Exception&) {
            break;
        } catch (const LinAlgError&) {
            break;
        }
        double move = 0.0;
        for (int k = 0; k < 4; ++k) {
            const double mv = std::sqrt(
                std::pow(fr2.corners.at<double>(k, 0) - corners.at<double>(k, 0), 2) +
                std::pow(fr2.corners.at<double>(k, 1) - corners.at<double>(k, 1), 2));
            move = std::max(move, mv);
        }
        if (fr2.size_res.board_size != n || fr2.size_res.margin < orig_margin * 0.5 ||
            move > 0.03 * diag)
            break;
        size_res = fr2.size_res;
        H_grid = fr2.H_grid;
        corners = fr2.corners;
        if (move < 0.005 * diag) break;
    }

    // shift-hypothesis search, on the one-line-off-slab impostor signature only.
    if (wood.has_value()) {
        try {
            const cv::Vec4d e = _slab_edge_scores(*wood, H_grid, size_res.board_size);
            int nLow = 0, nHigh = 0;
            for (int k = 0; k < 4; ++k) {
                if (e[k] < 0.25) ++nLow;
                if (e[k] >= 0.8) ++nHigh;
            }
            if (nLow == 1 && nHigh == 3) {
                const std::optional<cv::Mat> H_s =
                    _shift_search(gray, H_grid, size_res.board_size, *wood);
                if (H_s) {
                    const double q_old = lattice_quality(gray, H_grid, size_res.board_size);
                    if (lattice_quality(gray, *H_s, size_res.board_size) >= q_old - 0.5) {
                        H_grid = *H_s;
                        corners = _corners_of(toMatx33(H_grid), size_res.board_size);
                    }
                }
            }
        } catch (const cv::Exception&) {
        } catch (const LinAlgError&) {
        }
    }

    try {
        st = stone_stats(gray, H_grid, size_res.board_size);
    } catch (const cv::Exception&) {
        st = std::nullopt;
    } catch (const LinAlgError&) {
        st = std::nullopt;
    }

    if (st.has_value()) {
        if (st->B >= std::max(4.0, 0.25 * size_res.board_size)) {
            char buf[128];
            std::snprintf(buf, sizeof(buf),
                          "stone lattice continues off-board (%d aligned stones)",
                          static_cast<int>(st->B));
            throw DetectionError(buf);
        }
        // correction: adopt the stone-anchored refit if it does not degrade the
        // lattice evidence; else try the polished variant.
        if (st->A > 0.05) {
            try {
                const std::optional<cv::Mat> H_a =
                    stone_anchor_refit(gray, H_grid, size_res.board_size);
                if (H_a) {
                    const std::optional<StoneStats> st_a =
                        stone_stats(gray, *H_a, size_res.board_size);
                    const double q_cur = lattice_quality(gray, H_grid, size_res.board_size);
                    bool adopted = false;
                    if (st_a.has_value() && st_a->A <= 0.05 && st_a->resid <= 0.21 &&
                        st_a->B <= 3 &&
                        lattice_quality(gray, *H_a, size_res.board_size) >= q_cur) {
                        corners = _corners_of(toMatx33(*H_a), size_res.board_size);
                        H_grid = *H_a;
                        st = st_a;
                        adopted = true;
                    }
                    if (!adopted && st_a.has_value() && st_a->B <= 3 && st_a->A < st->A) {
                        const std::optional<cv::Mat> H_p_opt =
                            _refine_H_nodes(gray, *H_a, size_res.board_size);
                        const cv::Mat H_p = H_p_opt ? *H_p_opt : *H_a;
                        const std::optional<StoneStats> st_p =
                            stone_stats(gray, H_p, size_res.board_size);
                        if (st_p.has_value() && st_p->A <= st->A && st_p->B <= 3 &&
                            lattice_quality(gray, H_p, size_res.board_size) >=
                                q_cur + QUALITY_GAIN) {
                            corners = _corners_of(toMatx33(H_p), size_res.board_size);
                            H_grid = H_p;
                            st = st_p;
                        }
                    }
                }
            } catch (const cv::Exception&) {
            } catch (const LinAlgError&) {
            }
        }
    }

    // ambiguity gate (lower for a stone-verified lattice).
    const double gate = _verified(st, size_res.board_size) ? VERIFIED_GATE : min_size_margin;
    if (_eff_margin(size_res, st) < gate) {
        // "ambiguous board size (margin {margin:.2f}, scores {scores})". The
        // scores dict is Python's str(dict[int, np.float64]); numpy 2.x wraps a
        // scalar VALUE as "np.float64(<shortest repr>)" in a container's repr,
        // so the faithful form is "{9: np.float64(<repr>), ...}". (The embedded
        // digits still carry the choose_size warp HAL on a re-rectify, exactly
        // as the size_scores field does; the format/structure is what's exact.)
        std::string sc = "{";
        bool first = true;
        for (const auto& kv : size_res.scores) {
            if (!first) sc += ", ";
            first = false;
            sc += std::to_string(kv.first);
            sc += ": np.float64(";
            sc += py_float_repr(kv.second);
            sc += ")";
        }
        sc += "}";
        char mb[64];
        std::snprintf(mb, sizeof(mb), "%.2f", size_res.margin);
        throw DetectionError("ambiguous board size (margin " + std::string(mb) + ", scores " +
                             sc + ")");
    }

    // corners inside image (+-5px slack).
    double cx0 = corners.at<double>(0, 0), cx1 = cx0, cy0 = corners.at<double>(0, 1), cy1 = cy0;
    for (int k = 0; k < 4; ++k) {
        cx0 = std::min(cx0, corners.at<double>(k, 0));
        cx1 = std::max(cx1, corners.at<double>(k, 0));
        cy0 = std::min(cy0, corners.at<double>(k, 1));
        cy1 = std::max(cy1, corners.at<double>(k, 1));
    }
    if (cx0 < -5 || cx1 > wid + 5 || cy0 < -5 || cy1 > hgt + 5)
        throw DetectionError("grid corners outside image");

    // per-node polish (absorbs uniform-comb bias + snap noise).
    try {
        const std::optional<cv::Mat> H_ref = _refine_H_nodes(gray, H_grid, size_res.board_size);
        if (H_ref) {
            const cv::Mat c_ref = _corners_of(toMatx33(*H_ref), size_res.board_size);
            double rx0 = c_ref.at<double>(0, 0), rx1 = rx0, ry0 = c_ref.at<double>(0, 1),
                   ry1 = ry0;
            for (int k = 0; k < 4; ++k) {
                rx0 = std::min(rx0, c_ref.at<double>(k, 0));
                rx1 = std::max(rx1, c_ref.at<double>(k, 0));
                ry0 = std::min(ry0, c_ref.at<double>(k, 1));
                ry1 = std::max(ry1, c_ref.at<double>(k, 1));
            }
            if (rx0 >= -5 && rx1 <= wid + 5 && ry0 >= -5 && ry1 <= hgt + 5) {
                H_grid = *H_ref;
                corners = c_ref;
            }
        }
    } catch (const cv::Exception&) {
    } catch (const LinAlgError&) {
    }

    BoardDetection out;
    out.board_size = size_res.board_size;
    out.corners = corners;
    out.H_grid = H_grid;
    out.size_margin = size_res.margin;
    out.debug.quad_source = src;
    out.debug.size_scores = size_res.scores;
    return out;
}

}  // namespace gobanrecog

// ============================================================================
// Test / diagnostic bridge - defined HERE so it can reach the file-local statics
// above (the gr_grid/gr_stones/gr_stonelattice pattern). cv-free surface.
// ============================================================================

#include <cstring>

#include "include/GobanRecogTestBridge.hpp"

namespace gobanrecog {
namespace testbridge {

namespace {

void append_double(std::string& out, double v) {
    if (std::isnan(v)) { out += "NaN"; return; }
    if (std::isinf(v)) { out += (v > 0 ? "Infinity" : "-Infinity"); return; }
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%.17g", v);
    out += buf;
}

void append_json_string(std::string& out, const std::string& s) {
    out += '"';
    for (const char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    out += '"';
}

}  // namespace

// _verified(st, n) on a synthetic StoneStats (has_stats=0 -> None -> nullopt).
int detect_verified(int has_stats, int n_in, double A, double B, double resid, int n) {
    std::optional<gobanrecog::StoneStats> st;
    if (has_stats) st = gobanrecog::StoneStats{n_in, A, B, resid};
    return gobanrecog::_verified(st, n) ? 1 : 0;
}

// _eff_margin(size_res, st): scoreKeys/scoreVals build size_res.scores; margin +
// board_size complete it; has_stats/n_in/A/B/resid build the optional StoneStats.
double detect_eff_margin(const double* scoreKeys, const double* scoreVals, int nscores,
                         double margin, int board_size, int has_stats, int n_in, double A,
                         double B, double resid) {
    gobanrecog::SizeResult sr;
    sr.board_size = board_size;
    sr.margin = margin;
    for (int i = 0; i < nscores; ++i)
        sr.scores[static_cast<int>(scoreKeys[i])] = scoreVals[i];
    std::optional<gobanrecog::StoneStats> st;
    if (has_stats) st = gobanrecog::StoneStats{n_in, A, B, resid};
    return gobanrecog::_eff_margin(sr, st);
}

// lattice_quality(gray, H_grid, n): gray row-major uint8 HxW, h9 row-major 3x3.
double detect_lattice_quality(const unsigned char* gray, int width, int height,
                              const double* h9, int n) {
    const cv::Mat g(height, width, CV_8U, const_cast<unsigned char*>(gray));
    cv::Mat H(3, 3, CV_64F);
    for (int i = 0; i < 9; ++i) H.at<double>(i / 3, i % 3) = h9[i];
    return gobanrecog::lattice_quality(g, H, n);
}

// Micro-parity harness core: run detect_board on the RAW BGR image and emit the
// full boundary as JSON. On abstention (DetectionError) emit ok:false + reason.
std::string detect_stage_json(const unsigned char* bgr, int width, int height) {
    const cv::Mat img(height, width, CV_8UC3, const_cast<unsigned char*>(bgr));
    std::string out;
    out.reserve(1 << 10);
    out += "{\"stage\": \"detect\", ";
    try {
        const gobanrecog::BoardDetection det = gobanrecog::detect_board(img);
        out += "\"ok\": true, \"board_size\": ";
        out += std::to_string(det.board_size);
        out += ", \"quad_source\": ";
        append_json_string(out, det.debug.quad_source);
        out += ", \"H_grid\": [";
        for (int i = 0; i < 9; ++i) {
            if (i) out += ", ";
            append_double(out, det.H_grid.at<double>(i / 3, i % 3));
        }
        out += "], \"corners\": [";
        for (int k = 0; k < 4; ++k) {
            if (k) out += ", ";
            out += '[';
            append_double(out, det.corners.at<double>(k, 0));
            out += ", ";
            append_double(out, det.corners.at<double>(k, 1));
            out += ']';
        }
        out += "], \"size_scores\": {";
        bool first = true;
        for (const auto& kv : det.debug.size_scores) {
            if (!first) out += ", ";
            first = false;
            out += '"';
            out += std::to_string(kv.first);
            out += "\": ";
            append_double(out, kv.second);
        }
        out += "}}";
    } catch (const gobanrecog::DetectionError& e) {
        out += "\"ok\": false, \"error\": ";
        append_json_string(out, e.what());
        out += "}";
    } catch (const cv::Exception& e) {
        out += "\"ok\": false, \"error\": ";
        append_json_string(out, std::string("cv2.error: ") + e.what());
        out += "}";
    }
    return out;
}

}  // namespace testbridge
}  // namespace gobanrecog
