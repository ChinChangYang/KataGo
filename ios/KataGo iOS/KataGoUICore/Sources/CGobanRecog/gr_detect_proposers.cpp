//
//  gr_detect_proposers.cpp
//  CGobanRecog
//
//  Ports part A of gobanrecog/pipeline/detect.py line-by-line (port-conventions
//  rule 1): the candidate-quad GENERATION layer. See gr_detect_internal.h for
//  the exact A/B boundary. Only the four proposers + _wood_mask are exposed
//  (gr_detect_internal.h); every geometry/hough helper is file-local. The
//  gobanrecog::testbridge detect_* wrappers are ALSO defined at the bottom of
//  THIS file (not gr_testbridge.cpp) so they can reach the file-local statics -
//  the sanctioned cv-free test/diagnostic seam (pattern from gr_grid/gr_stones/
//  gr_stonelattice).
//
//  dtype fidelity (rule 2), all verified against numpy 2.5.1 / cv2 5.0.0 in the
//  reference venv (Task 7 probes - see task-7-report.md):
//    - _quad_texture: f = blur.astype(f32); mean/sq = boxFilter(f32) stay f32;
//      std = sqrt(clip(sq - mean*mean, 0, None)) stays f32; thr =
//      max(10.0, 0.35*float(np.percentile(std_f32, 99))) is a python double, but
//      the mask compare `std_f32 > thr` runs in FLOAT32 (NEP-50: f32 array vs
//      weak python float -> the scalar is cast to f32). PROVEN discriminating.
//    - _wood_mask: gray is uint8; thr = 0.75*float(np.percentile(gray, 90))
//      (uint8 -> float64 percentile); the compare `gray_u8 > thr` runs in
//      float64 (integer array vs python float -> float64) - and every uint8 int
//      is exact in both, so double(px) > thr is exact. median(gray[mask==1]) of
//      a uint8 selection is a float64 median.
//    - _line_params: length = np.hypot(dx,dy) (uses hypot); theta =
//      arctan2(dy,dx) % np.pi (fmod + wrap); rho = sin*x0 - cos*y0, all float64.
//    - _degenerate_quad: np.linalg.norm(axis=1) = sqrt(dx*dx+dy*dy) (NOT hypot,
//      PROVEN by the overflow-to-inf probe); sides.sum() is numpy pairwise.
//    - _extreme_lines: np.average(...) numerator/denominator are numpy pairwise
//      sums; the stored total weight `sum(weights)` is the PYTHON builtin sum
//      (naive from 0.0) - the two differ even at n=5 (PROVEN), so both are
//      honored. The rho sort is a stable sort (Python `sorted`, rule 7).
//
//  RNG: HoughLinesP uses OpenCV's own fixed-seed local RNG, independent of the
//  global seed, so no seeding is needed here (and detect.py seeds only before
//  the slat proposer, detect.py:929 - after part A).
//
//  #pragma STDC FP_CONTRACT OFF + the target's -ffp-contract=off (rule: numpy
//  does not fuse; keep new files un-fused).
//

#include "gr_detect_internal.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <opencv2/geometry.hpp>  // contourArea/convexHull/approxPolyDP/arcLength (OpenCV 5 moved them)
#include <opencv2/imgproc.hpp>   // Canny/dilate/findContours/HoughLinesP/boxFilter/morphologyEx

#include "gr_parity.h"

#pragma STDC FP_CONTRACT OFF

namespace gobanrecog {

namespace {

// ---- shared geometry helpers (file-local) ----------------------------------

// ports detect.py::_order_quad. pts: 4x2 CV_64F. Returns the same 4 points
// ordered TL, TR, BR, BL = argmin(x+y), argmax(x-y), argmax(x+y), argmin(x-y),
// each argmin/argmax taking numpy's FIRST occurrence on ties.
cv::Mat _order_quad(const cv::Mat& pts) {
    double s[4], d[4];
    for (int i = 0; i < 4; ++i) {
        const double x = pts.at<double>(i, 0);
        const double y = pts.at<double>(i, 1);
        s[i] = x + y;  // pts.sum(axis=1)
        d[i] = x - y;  // pts[:,0] - pts[:,1]
    }
    int amin_s = 0, amax_d = 0, amax_s = 0, amin_d = 0;
    for (int i = 1; i < 4; ++i) {
        if (s[i] < s[amin_s]) amin_s = i;  // s.argmin() (first on ties)
        if (d[i] > d[amax_d]) amax_d = i;  // d.argmax()
        if (s[i] > s[amax_s]) amax_s = i;  // s.argmax()
        if (d[i] < d[amin_d]) amin_d = i;  // d.argmin()
    }
    const int order[4] = {amin_s, amax_d, amax_s, amin_d};
    cv::Mat out(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        out.at<double>(k, 0) = pts.at<double>(order[k], 0);
        out.at<double>(k, 1) = pts.at<double>(order[k], 1);
    }
    return out;
}

// ports detect.py::_degenerate_quad. True when the ordered quad has a
// (near-)zero-length side: min side < 0.05 * sum of sides.
bool _degenerate_quad(const cv::Mat& quad) {
    double sides[4];
    for (int i = 0; i < 4; ++i) {
        const int j = (i + 1) % 4;  // np.roll(quad, -1, axis=0)
        const double dx = quad.at<double>(j, 0) - quad.at<double>(i, 0);
        const double dy = quad.at<double>(j, 1) - quad.at<double>(i, 1);
        sides[i] = std::sqrt(dx * dx + dy * dy);  // norm = sqrt(x^2+y^2), NOT hypot
    }
    const double sum = np_pairwise_sum(sides, 4);  // sides.sum() (numpy pairwise)
    double mn = sides[0];
    for (int i = 1; i < 4; ++i)
        if (sides[i] < mn) mn = sides[i];
    return mn < 0.05 * sum;
}

// First contour with maximal area (Python `max(contours, key=cv2.contourArea)`
// returns the FIRST maximal element).
size_t _max_by_area(const std::vector<std::vector<cv::Point>>& cs) {
    size_t best = 0;
    double ba = cv::contourArea(cs[0]);
    for (size_t i = 1; i < cs.size(); ++i) {
        const double a = cv::contourArea(cs[i]);
        if (a > ba) {  // strict > keeps the first max
            ba = a;
            best = i;
        }
    }
    return best;
}

// Build the ordered quad from a 4-vertex approxPolyDP result (int points ->
// float64 -> _order_quad). Shared by the hull/texture/slab sweeps.
cv::Mat _order_from_approx(const std::vector<cv::Point>& approx) {
    cv::Mat pts(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        pts.at<double>(k, 0) = static_cast<double>(approx[k].x);
        pts.at<double>(k, 1) = static_cast<double>(approx[k].y);
    }
    return _order_quad(pts);
}

// ---- hough helpers (file-local) --------------------------------------------

// ports the numpy scalar `x % np.pi` (fmod + wrap into [0, pi)). np.pi == CV_PI
// as a double. Verified bit-exact vs numpy 2.5.1 over the arctan2 domain.
double pymod_pi(double x) {
    double r = std::fmod(x, CV_PI);
    if (r < 0.0) r += CV_PI;
    return r;
}

// ports detect.py::_line_params. Segment (x0,y0,x1,y1) -> (theta, rho, length).
struct Seg {
    double theta;
    double rho;
    double length;
};

Seg _line_params(const cv::Vec4i& seg) {
    const double x0 = static_cast<double>(seg[0]);  // map(float, seg)
    const double y0 = static_cast<double>(seg[1]);
    const double x1 = static_cast<double>(seg[2]);
    const double y1 = static_cast<double>(seg[3]);
    const double dx = x1 - x0;
    const double dy = y1 - y0;
    const double length = std::hypot(dx, dy);        // np.hypot(dx, dy)
    const double theta = pymod_pi(std::atan2(dy, dx));  // arctan2(dy,dx) % np.pi
    const double nx = std::sin(theta);
    const double ny = -std::cos(theta);
    const double rho = nx * x0 + ny * y0;
    return {theta, rho, length};
}

// scored cluster tuple (weighted rho, weighted theta, total length).
struct Scored {
    double rho;
    double theta;
    double weight;
};

// ports detect.py::_extreme_lines. segs are already the same family (horiz or
// vert). Returns the two extreme merged lines as (theta, rho) - matching
// _line_params' order for _intersect - i.e. np.array([lo[1], lo[0]]).
std::pair<cv::Vec2d, cv::Vec2d> _extreme_lines(std::vector<Seg> segs) {
    // segs = sorted(segs, key=lambda t: t[1])  -> stable sort by rho (rule 7)
    std::stable_sort(segs.begin(), segs.end(),
                     [](const Seg& a, const Seg& b) { return nanLastAscending(a.rho, b.rho); });

    std::vector<std::vector<Seg>> clusters;
    for (const Seg& t : segs) {
        if (!clusters.empty()) {
            // np.average([c[1] for c in clusters[-1]])  (unweighted mean of rho)
            std::vector<double> rr;
            rr.reserve(clusters.back().size());
            for (const Seg& c : clusters.back()) rr.push_back(c.rho);
            const double mean = np_mean(rr.data(), rr.size());
            if (std::abs(t.rho - mean) < 8.0) {
                clusters.back().push_back(t);
                continue;
            }
        }
        clusters.push_back({t});
    }

    std::vector<Scored> scored;
    scored.reserve(clusters.size());
    for (const std::vector<Seg>& c : clusters) {
        std::vector<double> rhoW, thetaW, w;
        rhoW.reserve(c.size());
        thetaW.reserve(c.size());
        w.reserve(c.size());
        for (const Seg& t : c) {
            rhoW.push_back(t.rho * t.length);
            thetaW.push_back(t.theta * t.length);
            w.push_back(t.length);
        }
        // np.average(..., weights=weights): numerator/denominator numpy pairwise
        const double denom = np_pairwise_sum(w.data(), w.size());
        const double arho = np_pairwise_sum(rhoW.data(), rhoW.size()) / denom;
        const double atheta = np_pairwise_sum(thetaW.data(), thetaW.size()) / denom;
        // sum(weights): PYTHON builtin sum (naive from 0.0), NOT numpy pairwise
        double totw = 0.0;
        for (const double x : w) totw += x;
        scored.push_back({arho, atheta, totw});
    }

    if (scored.size() < 2) throw DetectionError("not enough line clusters");

    // max_w = max(s[2] for s in scored)  (value only)
    double max_w = scored[0].weight;
    for (const Scored& s : scored)
        if (s.weight > max_w) max_w = s.weight;

    // good = [s for s in scored if s[2] > 0.25 * max_w]  (order preserved)
    std::vector<Scored> good;
    for (const Scored& s : scored)
        if (s.weight > 0.25 * max_w) good.push_back(s);

    // lo = min(good, key=s[0]) ; hi = max(good, key=s[0])  (first occurrence)
    Scored lo = good[0], hi = good[0];
    for (const Scored& s : good)
        if (s.rho < lo.rho) lo = s;  // first min (strict <)
    for (const Scored& s : good)
        if (s.rho > hi.rho) hi = s;  // first max (strict >)

    if (hi.rho - lo.rho < 50.0) throw DetectionError("line families degenerate");
    return {cv::Vec2d(lo.theta, lo.rho), cv::Vec2d(hi.theta, hi.rho)};
}

// ports detect.py::_intersect. l = (theta, rho). Solves the 2x2 line system;
// throws LinAlgError on a singular system (np.linalg.solve).
cv::Vec2d _intersect(const cv::Vec2d& l1, const cv::Vec2d& l2) {
    cv::Mat a(2, 2, CV_64F);
    a.at<double>(0, 0) = std::sin(l1[0]);
    a.at<double>(0, 1) = -std::cos(l1[0]);
    a.at<double>(1, 0) = std::sin(l2[0]);
    a.at<double>(1, 1) = -std::cos(l2[0]);
    const cv::Vec2d b(l1[1], l2[1]);
    return solve2x2(a, b);
}

// ports detect.py::_quad_hough's post-HoughLinesP tail (the horiz/vert split ->
// _extreme_lines -> _intersect -> isfinite check -> _order_quad). Factored out
// so the test bridge can exercise the full pure logic on synthetic segments.
cv::Mat _hough_quad(const std::vector<cv::Vec4i>& lines) {
    std::vector<Seg> horiz, vert;
    for (const cv::Vec4i& seg : lines) {
        const Seg lp = _line_params(seg);
        if (std::min(lp.theta, CV_PI - lp.theta) < CV_PI / 4.0)
            horiz.push_back(lp);
        else
            vert.push_back(lp);
    }
    if (horiz.size() < 2 || vert.size() < 2)
        throw DetectionError("missing a line family");
    const std::pair<cv::Vec2d, cv::Vec2d> tb = _extreme_lines(horiz);  // top, bottom
    const std::pair<cv::Vec2d, cv::Vec2d> lr = _extreme_lines(vert);   // left, right
    const cv::Vec2d& top = tb.first;
    const cv::Vec2d& bottom = tb.second;
    const cv::Vec2d& left = lr.first;
    const cv::Vec2d& right = lr.second;
    cv::Mat quad(4, 2, CV_64F);
    const cv::Vec2d corners[4] = {_intersect(top, left), _intersect(top, right),
                                  _intersect(bottom, right), _intersect(bottom, left)};
    for (int k = 0; k < 4; ++k) {
        quad.at<double>(k, 0) = corners[k][0];
        quad.at<double>(k, 1) = corners[k][1];
    }
    for (int k = 0; k < 4; ++k)  // np.isfinite(quad).all()
        if (!std::isfinite(quad.at<double>(k, 0)) || !std::isfinite(quad.at<double>(k, 1)))
            throw DetectionError("degenerate quad");
    return _order_quad(quad);
}

}  // namespace

// ============================================================================
// Proposers (declared in gr_detect_internal.h).
// ============================================================================

// ports detect.py::_quad_hull.
cv::Mat _quad_hull(const cv::Mat& gray, int dilate_iterations) {
    cv::Mat edges;
    cv::Canny(gray, edges, 30, 90);
    cv::dilate(edges, edges, cv::Mat::ones(3, 3, CV_8U), cv::Point(-1, -1),
               dilate_iterations);
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    if (contours.empty()) throw DetectionError("no contours");

    // hulls = [convexHull(c) for c in contours]; hull = max(hulls, key=area)
    std::vector<cv::Point> hull;
    double hullArea = 0.0;
    bool have = false;
    for (const std::vector<cv::Point>& c : contours) {
        std::vector<cv::Point> h;
        cv::convexHull(c, h);
        const double a = cv::contourArea(h);
        if (!have || a > hullArea) {  // first max (strict >)
            hullArea = a;
            hull = h;
            have = true;
        }
    }
    if (hullArea < 0.10 * static_cast<double>(gray.total()))
        throw DetectionError("largest edge blob too small");

    const double peri = cv::arcLength(hull, true);
    for (const double eps : np_arange(0.01, 0.12, 0.01)) {
        std::vector<cv::Point> approx;
        cv::approxPolyDP(hull, approx, eps * peri, true);
        if (approx.size() == 4) return _order_from_approx(approx);
    }
    throw DetectionError("hull not quad-like");
}

// ports detect.py::_quad_hough.
cv::Mat _quad_hough(const cv::Mat& gray) {
    const int h = gray.rows, w = gray.cols;
    cv::Mat edges;
    cv::Canny(gray, edges, 40, 120);
    std::vector<cv::Vec4i> lines;
    cv::HoughLinesP(edges, lines, 1, CV_PI / 360.0, 60,
                    0.30 * std::min(w, h), 8);
    if (lines.size() < 4) throw DetectionError("no long lines found");
    return _hough_quad(lines);
}

// ports detect.py::_quad_texture.
cv::Mat _quad_texture(const cv::Mat& gray) {
    cv::Mat blur;
    cv::GaussianBlur(gray, blur, cv::Size(5, 5), 0);
    cv::Mat f;
    blur.convertTo(f, CV_32F);  // blur.astype(np.float32)
    cv::Mat mean, sq;
    cv::boxFilter(f, mean, -1, cv::Size(15, 15));
    cv::boxFilter(f.mul(f), sq, -1, cv::Size(15, 15));  // f * f -> boxFilter
    cv::Mat diff = sq - mean.mul(mean);
    diff = cv::max(diff, 0.0);  // np.clip(x, 0, None)
    cv::Mat stdm;
    cv::sqrt(diff, stdm);  // np.sqrt (all CV_32F)

    // thr = max(10.0, 0.35 * float(np.percentile(std, 99)))  [float32 path]
    std::vector<float> sv;
    sv.reserve(stdm.total());
    for (int y = 0; y < stdm.rows; ++y) {
        const float* p = stdm.ptr<float>(y);
        for (int x = 0; x < stdm.cols; ++x) sv.push_back(p[x]);
    }
    const double pct = static_cast<double>(np_percentile(sv, 99.0));  // f32 -> promote
    const double thr = std::max(10.0, 0.35 * pct);
    const float thrF = static_cast<float>(thr);  // NEP-50: compare in float32

    // mask = (std > thr).astype(uint8)  (0/1)
    cv::Mat mask(stdm.size(), CV_8U);
    for (int y = 0; y < stdm.rows; ++y) {
        const float* p = stdm.ptr<float>(y);
        uchar* m = mask.ptr<uchar>(y);
        for (int x = 0; x < stdm.cols; ++x) m[x] = (p[x] > thrF) ? 1 : 0;
    }
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, cv::Mat::ones(15, 15, CV_8U));

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    if (contours.empty()) throw DetectionError("no textured region");
    std::vector<cv::Point> hull;
    cv::convexHull(contours[_max_by_area(contours)], hull);
    if (cv::contourArea(hull) < 0.05 * static_cast<double>(gray.total()))
        throw DetectionError("textured region too small");

    const double peri = cv::arcLength(hull, true);
    for (const double eps : np_arange(0.01, 0.12, 0.01)) {
        std::vector<cv::Point> approx;
        cv::approxPolyDP(hull, approx, eps * peri, true);
        if (approx.size() == 4 &&
            cv::contourArea(approx) > 0.05 * static_cast<double>(gray.total()))
            return _order_from_approx(approx);
    }
    throw DetectionError("textured hull not quad-like");
}

// ports detect.py::_wood_mask.
std::optional<cv::Mat> _wood_mask(const cv::Mat& img_bgr) {
    cv::Mat gray;
    cv::cvtColor(img_bgr, gray, cv::COLOR_BGR2GRAY);

    // thr = 0.75 * float(np.percentile(gray, 90))  [uint8 -> float64 percentile]
    std::vector<double> gv;
    gv.reserve(gray.total());
    for (int y = 0; y < gray.rows; ++y) {
        const uchar* p = gray.ptr<uchar>(y);
        for (int x = 0; x < gray.cols; ++x) gv.push_back(static_cast<double>(p[x]));
    }
    const double thr = 0.75 * np_percentile(gv, 90.0);

    // raw = (gray > thr).astype(uint8)  [float64 compare; uint8 ints are exact]
    cv::Mat raw(gray.size(), CV_8U);
    for (int y = 0; y < gray.rows; ++y) {
        const uchar* p = gray.ptr<uchar>(y);
        uchar* r = raw.ptr<uchar>(y);
        for (int x = 0; x < gray.cols; ++x)
            r[x] = (static_cast<double>(p[x]) > thr) ? 1 : 0;
    }
    cv::morphologyEx(raw, raw, cv::MORPH_CLOSE, cv::Mat::ones(25, 25, CV_8U));
    cv::morphologyEx(raw, raw, cv::MORPH_OPEN, cv::Mat::ones(9, 9, CV_8U));

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(raw, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    if (contours.empty()) return std::nullopt;
    const size_t bi = _max_by_area(contours);
    if (cv::contourArea(contours[bi]) < 0.15 * static_cast<double>(gray.total()))
        return std::nullopt;

    cv::Mat mask = cv::Mat::zeros(raw.size(), CV_8U);  // np.zeros_like(raw)
    const std::vector<std::vector<cv::Point>> one{contours[bi]};
    cv::drawContours(mask, one, -1, cv::Scalar(1), -1);  // filled, value 1

    cv::Mat dil;
    cv::dilate(mask, dil, cv::Mat::ones(31, 31, CV_8U));
    const cv::Mat ring = dil - mask;  // 0/1 (dilate >= mask elementwise)
    if (static_cast<int>(cv::sum(ring)[0]) < 500) return std::nullopt;

    // inner/outer = median of gray over mask==1 / ring==1 (uint8 -> float64)
    std::vector<double> innerV, outerV;
    for (int y = 0; y < gray.rows; ++y) {
        const uchar* g = gray.ptr<uchar>(y);
        const uchar* m = mask.ptr<uchar>(y);
        const uchar* rr = ring.ptr<uchar>(y);
        for (int x = 0; x < gray.cols; ++x) {
            if (m[x] == 1) innerV.push_back(static_cast<double>(g[x]));
            if (rr[x] == 1) outerV.push_back(static_cast<double>(g[x]));
        }
    }
    const double inner = np_median(innerV);
    const double outer = np_median(outerV);
    if (outer > 0.85 * inner) return std::nullopt;
    return mask;
}

// ports detect.py::_quad_slab.
cv::Mat _quad_slab(const cv::Mat& img_bgr) {
    const std::optional<cv::Mat> maskOpt = _wood_mask(img_bgr);
    if (!maskOpt) throw DetectionError("no confident wood slab");
    const cv::Mat mask = *maskOpt;

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    std::vector<cv::Point> hull;
    cv::convexHull(contours[_max_by_area(contours)], hull);

    const double peri = cv::arcLength(hull, true);
    for (const double eps : np_arange(0.01, 0.12, 0.01)) {
        std::vector<cv::Point> approx;
        cv::approxPolyDP(hull, approx, eps * peri, true);
        if (approx.size() == 4 &&
            cv::contourArea(approx) > 0.05 * static_cast<double>(mask.total())) {
            const cv::Mat quad = _order_from_approx(approx);
            if (_degenerate_quad(quad)) continue;  // img_00339: collapsed corners
            return quad;
        }
    }
    throw DetectionError("wood slab not quad-like");
}

}  // namespace gobanrecog

// ============================================================================
// Test / diagnostic bridge - defined HERE so it can reach the file-local
// statics above (pattern from gr_stonelattice.cpp). cv-free surface.
// ============================================================================

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

// Escape a DetectionError reason for JSON (reasons are plain ASCII, but keep it
// safe against " and \).
void append_json_string(std::string& out, const std::string& s) {
    out += '"';
    for (const char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    out += '"';
}

// Run one proposer, appending its JSON object: {"ok":true,"quad":[[x,y]*4]} or
// {"ok":false,"error_type":"...","reason":"..."} (reason only for
// DetectionError - cv2.error / LinAlgError messages differ across builds).
template <class Fn>
void append_proposer(std::string& out, const char* name, Fn&& fn) {
    out += '"';
    out += name;
    out += "\": ";
    try {
        const cv::Mat q = fn();
        out += "{\"ok\": true, \"quad\": [";
        for (int k = 0; k < 4; ++k) {
            if (k) out += ", ";
            out += '[';
            append_double(out, q.at<double>(k, 0));
            out += ", ";
            append_double(out, q.at<double>(k, 1));
            out += ']';
        }
        out += "]}";
    } catch (const DetectionError& e) {
        out += "{\"ok\": false, \"error_type\": \"DetectionError\", \"reason\": ";
        append_json_string(out, e.what());
        out += "}";
    } catch (const LinAlgError&) {
        out += "{\"ok\": false, \"error_type\": \"LinAlgError\", \"reason\": \"\"}";
    } catch (const cv::Exception&) {
        out += "{\"ok\": false, \"error_type\": \"cv2.error\", \"reason\": \"\"}";
    }
}

}  // namespace

void detect_order_quad(const double* pts8, double* out8) {
    cv::Mat pts(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        pts.at<double>(k, 0) = pts8[2 * k];
        pts.at<double>(k, 1) = pts8[2 * k + 1];
    }
    const cv::Mat q = gobanrecog::_order_quad(pts);
    for (int k = 0; k < 4; ++k) {
        out8[2 * k] = q.at<double>(k, 0);
        out8[2 * k + 1] = q.at<double>(k, 1);
    }
}

int detect_degenerate_quad(const double* quad8) {
    cv::Mat q(4, 2, CV_64F);
    for (int k = 0; k < 4; ++k) {
        q.at<double>(k, 0) = quad8[2 * k];
        q.at<double>(k, 1) = quad8[2 * k + 1];
    }
    return gobanrecog::_degenerate_quad(q) ? 1 : 0;
}

int detect_hull_sweep(const int* hullXY, int nHull, double* outQuad8) {
    std::vector<cv::Point> hull(nHull);
    for (int i = 0; i < nHull; ++i) hull[i] = cv::Point(hullXY[2 * i], hullXY[2 * i + 1]);
    const double peri = cv::arcLength(hull, true);
    for (const double eps : gobanrecog::np_arange(0.01, 0.12, 0.01)) {
        std::vector<cv::Point> approx;
        cv::approxPolyDP(hull, approx, eps * peri, true);
        if (approx.size() == 4) {
            const cv::Mat q = gobanrecog::_order_from_approx(approx);
            for (int k = 0; k < 4; ++k) {
                outQuad8[2 * k] = q.at<double>(k, 0);
                outQuad8[2 * k + 1] = q.at<double>(k, 1);
            }
            return 1;
        }
    }
    return 0;  // "hull not quad-like" path
}

int detect_hough_from_segments(const int* segsXYXY, int nSegs, double* outQuad8,
                               char* reason, int reasonCap) {
    std::vector<cv::Vec4i> lines(nSegs);
    for (int i = 0; i < nSegs; ++i)
        lines[i] = cv::Vec4i(segsXYXY[4 * i], segsXYXY[4 * i + 1],
                             segsXYXY[4 * i + 2], segsXYXY[4 * i + 3]);
    try {
        const cv::Mat q = gobanrecog::_hough_quad(lines);
        for (int k = 0; k < 4; ++k) {
            outQuad8[2 * k] = q.at<double>(k, 0);
            outQuad8[2 * k + 1] = q.at<double>(k, 1);
        }
        return 1;
    } catch (const DetectionError& e) {
        std::snprintf(reason, static_cast<size_t>(reasonCap), "%s", e.what());
        return 0;
    }
}

std::string proposers_stage_json(const unsigned char* bgr, int width, int height) {
    const cv::Mat img(height, width, CV_8UC3, const_cast<unsigned char*>(bgr));
    cv::Mat gray;
    cv::cvtColor(img, gray, cv::COLOR_BGR2GRAY);  // detect_board:860
    std::string out;
    out.reserve(1 << 12);
    out += "{\"stage\": \"proposers\", ";
    // Order mirrors detect_board's proposers tuple (detect.py:882-888).
    append_proposer(out, "hull", [&] { return gobanrecog::_quad_hull(gray, 2); });
    out += ", ";
    append_proposer(out, "hough", [&] { return gobanrecog::_quad_hough(gray); });
    out += ", ";
    append_proposer(out, "hull1", [&] { return gobanrecog::_quad_hull(gray, 1); });
    out += ", ";
    append_proposer(out, "texture", [&] { return gobanrecog::_quad_texture(gray); });
    out += ", ";
    append_proposer(out, "slab", [&] { return gobanrecog::_quad_slab(img); });
    out += "}";
    return out;
}

}  // namespace testbridge
}  // namespace gobanrecog
