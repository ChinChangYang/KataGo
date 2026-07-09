//
//  gr_grid.cpp
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/grid.py line-by-line (port-conventions.md rule 1).
//  Only {SizeResult, rectify_quad, line_profiles, choose_size} are exposed via
//  gr_grid.h (detect.py's import surface); every other grid.py function is
//  file-local here. The gobanrecog::testbridge grid_* wrappers are ALSO defined
//  at the bottom of this file (not in gr_testbridge.cpp) so they can reach the
//  file-local statics — the sanctioned cv-free test/diagnostic seam.
//
//  dtype fidelity (rule 2), all verified against numpy 2.5.1 in the reference
//  venv (Task 4 probes):
//    - profiles are float32 (numpy sums uint8 blackhat rows .astype(np.float32));
//      their means/medians/percentiles are computed IN float32 (NEP 50 keeps
//      np.float32 (+|-|*|/) python-float in float32), using the gr_parity
//      helpers np_mean / np_median / np_percentile(float32).
//    - stoneness/avg are float64: rect.astype(np.float32) - np.median(uint8)
//      promotes to float64 under NEP 50 (np.float64 scalar is "strong").
//    - _penalized's penalty arm promotes to float64: np.float32 * np.int64 ->
//      float64 (verified), so score = f64(score_f32) - f64(0.8f*score_f32) *
//      unexplained / n.
//    - int(round(x)) / round(np.float64) are half-to-even -> np_round.
//    - np.arange fills start + i*delta -> np_arange.
//

#include "gr_grid.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>  // getPerspectiveTransform (OpenCV 5.0 moved it here)
#include <opencv2/imgproc.hpp>

#include "GobanRecogTestBridge.hpp"
#include "gr_constants.h"
#include "gr_parity.h"

// numpy never fuses multiply-add into FMA (each op rounds separately); forbid
// contraction so the float32 threshold/score arithmetic rounds like numpy's.
#pragma STDC FP_CONTRACT OFF

namespace gobanrecog {

namespace {

// (score, offset, spacing) comb-fit triple — the Python (float, float, float)
// tuple, same field order (conventions rule 6). The score holds the value of
// the numpy scalar (float32-rounded where numpy computed in float32).
struct Cand {
    double score;
    double o;
    double s;
};

inline const float* prof_ptr(const cv::Mat& prof) {
    CV_Assert(prof.type() == CV_32F && prof.rows == 1);
    return prof.ptr<float>(0);
}

inline int prof_len(const cv::Mat& prof) {
    return prof.cols;
}

// prof[np.clip(np.round(o + s*np.arange(n)).astype(int), 0, len(prof)-1)]
std::vector<float> gather_teeth(const float* p, int len, int n, double o, double s) {
    std::vector<float> teeth(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        int idx = static_cast<int>(np_round(o + s * k));
        idx = std::min(std::max(idx, 0), len - 1);
        teeth[static_cast<size_t>(k)] = p[idx];
    }
    return teeth;
}

// ports grid.py::_profile_peaks — local maxima above a robust threshold,
// non-max suppressed.
std::vector<double> _profile_peaks(const cv::Mat& prof, double min_sep) {
    const float* p = prof_ptr(prof);
    const int len = prof_len(prof);
    // inner = prof[PAD // 2 : len(prof) - PAD // 2]
    const int a = RECT_PAD / 2;
    std::vector<float> inner(p + a, p + (len - a));
    // thr = np.median(inner) + 0.30 * (np.percentile(inner, 99.5) - np.median(inner))
    // (all float32: median/percentile of a float32 array are float32, and
    //  NEP 50 keeps python-float arithmetic on them in float32)
    const cv::Mat innerMat(1, static_cast<int>(inner.size()), CV_32F, inner.data());
    const float med = static_cast<float>(np_median(innerMat));
    const float perc = np_percentile(inner, 99.5);
    const float thr = med + 0.30f * (perc - med);
    std::vector<int> idx;
    for (int i = 2; i < len - 2; ++i) {
        if (p[i] > thr && p[i] >= p[i - 1] && p[i] >= p[i + 1]) {
            idx.push_back(i);
        }
    }
    // idx.sort(key=lambda i: -prof[i]) — Python's sort is stable; ties keep
    // ascending index order.
    std::stable_sort(idx.begin(), idx.end(), [p](int x, int y) { return p[x] > p[y]; });
    std::vector<int> kept;
    for (int i : idx) {
        bool ok = true;
        for (int j : kept) {
            if (std::abs(i - j) < min_sep) {  // all(abs(i-j) >= min_sep ...)
                ok = false;
                break;
            }
        }
        if (ok) kept.push_back(i);
    }
    std::sort(kept.begin(), kept.end());
    return std::vector<double>(kept.begin(), kept.end());
}

// ports grid.py::_penalized — comb score with a penalty for strong peaks not
// explained by any tooth — both inside the comb span and up to ~1 spacing
// beyond its ends (catches one-line shifts).
double _penalized(const cv::Mat& prof, const std::vector<double>& peaks, int n,
                  double o, double s) {
    const float* p = prof_ptr(prof);
    const int len = prof_len(prof);
    std::vector<double> pos(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) pos[static_cast<size_t>(k)] = o + s * k;
    const std::vector<float> teeth = gather_teeth(p, len, n, o, s);
    // score = teeth.mean() / (prof.mean() + 1e-9)   (float32 throughout)
    const float score_f = np_mean(teeth.data(), teeth.size()) /
                          (np_mean(p, static_cast<size_t>(len)) + 1e-9f);
    double score = static_cast<double>(score_f);
    // profiles are zeroed outside the quad, so peaks already live in
    // [PAD, PAD+SPAN]; charging every comb of a given n for ALL of them makes
    // the penalty comb-independent — a shifted comb can no longer dodge junk
    // peaks by sliding its window
    if (!peaks.empty()) {
        // d = np.abs(peaks[:, None] - pos[None, :]).min(axis=1)
        // unexplained = (d > 0.25 * s).sum()
        long long unexplained = 0;
        for (double pk : peaks) {
            double d = std::numeric_limits<double>::infinity();
            for (double q : pos) d = std::min(d, std::fabs(pk - q));
            if (d > 0.25 * s) ++unexplained;
        }
        // score -= 0.8 * score * unexplained / n
        // numpy: (0.8 * score) is float32; float32 * np.int64 promotes to
        // float64, so the penalty arm (and the final score) is float64.
        score = static_cast<double>(score_f) -
                static_cast<double>(0.8f * score_f) * static_cast<double>(unexplained) / n;
    }
    return score;
}

// ports grid.py::_comb_candidates — top-k distinct (score, offset, spacing)
// comb fits against a profile.
//
// Multiple candidates matter on dense boards: the wood gaps between stones
// fire the ridge response at HALF-lattice positions, so the best line-only
// comb can sit half a spacing off. The stone-contrast term in choose_size
// disambiguates — but only if the true comb is among the candidates.
std::vector<Cand> _comb_candidates(const cv::Mat& prof, int n,
                                   const std::vector<double>& peaks, int k = 3) {
    const float* p = prof_ptr(prof);
    const int len = prof_len(prof);
    const double s_min = SPAN / (n - 1 + 2 * MAX_MARGIN);
    const double s_max = SPAN / static_cast<double>(n - 1);
    const float norm = np_mean(p, static_cast<size_t>(len)) + 1e-9f;
    std::vector<Cand> grid_scores;
    for (double s : np_arange(s_min, s_max + 0.25, 0.5)) {
        const double o_max = RECT_PAD + (SPAN - (n - 1) * s) + 4.0;
        for (double o : np_arange(RECT_PAD - 2.0, o_max, 2.0)) {
            const std::vector<float> teeth = gather_teeth(p, len, n, o, s);
            const float sc = np_mean(teeth.data(), teeth.size()) / norm;
            grid_scores.push_back({static_cast<double>(sc), o, s});
        }
    }
    // grid_scores.sort(key=lambda t: -t[0]) — stable.
    std::stable_sort(grid_scores.begin(), grid_scores.end(),
                     [](const Cand& x, const Cand& y) { return x.score > y.score; });
    // keep top-k solutions that differ meaningfully in offset or spacing
    std::vector<Cand> seeds;
    for (const Cand& g : grid_scores) {
        bool distinct = true;
        for (const Cand& sd : seeds) {
            if (!(std::fabs(g.o - sd.o) > 0.25 * g.s || std::fabs(g.s - sd.s) > 0.05 * g.s)) {
                distinct = false;
                break;
            }
        }
        if (distinct) seeds.push_back(g);
        if (static_cast<int>(seeds.size()) >= k) break;
    }
    std::vector<Cand> out;
    for (const Cand& sd : seeds) {
        const double o0 = sd.o;
        const double s0 = sd.s;
        Cand best = {-std::numeric_limits<double>::infinity(), o0, s0};
        for (double s : np_arange(s0 - 0.6, s0 + 0.6, 0.1)) {
            for (double o : np_arange(o0 - 2.4, o0 + 2.4, 0.4)) {
                const double pos_last = o + s * (n - 1);
                if (pos_last > RECT_PAD + SPAN + 6 || o < RECT_PAD - 8) continue;
                const double sc = _penalized(prof, peaks, n, o, s);
                if (sc > best.score) best = {sc, o, s};
            }
        }
        out.push_back(best);
    }
    std::stable_sort(out.begin(), out.end(),
                     [](const Cand& x, const Cand& y) { return x.score > y.score; });
    return out;
}

// ports grid.py::stoneness_map — disk-averaged deviation from the median wood
// tone, plus its scale. `stoneness`/`avg` are float64: under NEP 50
// rect.astype(np.float32) - np.median(...) (a float64 scalar) promotes to
// float64 (verified in the venv).
std::pair<cv::Mat, double> stoneness_map(const cv::Mat& rect, double spacing) {
    CV_Assert(rect.type() == CV_8U);
    const int lo = RECT_PAD;
    const int hi = RECT_PAD + SPAN;
    const double med = np_median(rect(cv::Range(lo, hi), cv::Range(lo, hi)));
    cv::Mat stoneness(rect.rows, rect.cols, CV_64F);
    for (int i = 0; i < rect.rows; ++i) {
        const unsigned char* src = rect.ptr<unsigned char>(i);
        double* dst = stoneness.ptr<double>(i);
        for (int j = 0; j < rect.cols; ++j) {
            // np.abs(rect.astype(np.float32) - med): uint8 -> float32 is exact,
            // so the float64 subtraction below is bit-identical.
            dst[j] = std::fabs(static_cast<double>(src[j]) - med);
        }
    }
    // the table beyond the quad also deviates from the wood median — mask it
    // out so near-boundary sample points can't inherit fake stone support
    stoneness.rowRange(0, lo) = 0.0;
    stoneness.rowRange(hi, stoneness.rows) = 0.0;
    stoneness.colRange(0, lo) = 0.0;
    stoneness.colRange(hi, stoneness.cols) = 0.0;
    // 0.25*spacing (not the stone radius): a tighter disk doubles the
    // true-vs-shifted lattice contrast on dense boards
    const int r = std::max(2, static_cast<int>(np_round(0.25 * spacing)));
    cv::Mat kernel8 = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * r + 1, 2 * r + 1));
    cv::Mat kernel;
    kernel8.convertTo(kernel, CV_32F);
    // kernel /= kernel.sum(): the sum of 0/1 float32 cells is an exact integer,
    // and numpy divides per element in float32 — do the same explicitly.
    const float ksum = np_pairwise_sum(kernel.ptr<float>(0), kernel.total());
    for (int i = 0; i < kernel.rows; ++i) {
        float* kr = kernel.ptr<float>(i);
        for (int j = 0; j < kernel.cols; ++j) kr[j] = kr[j] / ksum;
    }
    cv::Mat avg;
    cv::filter2D(stoneness, avg, -1, kernel);
    // scale = float(np.percentile(stoneness[lo:hi, lo:hi], 95)) + 1e-6
    std::vector<double> interior;
    interior.reserve(static_cast<size_t>(SPAN) * SPAN);
    for (int i = lo; i < hi; ++i) {
        const double* row = stoneness.ptr<double>(i);
        interior.insert(interior.end(), row + lo, row + hi);
    }
    const double scale = np_percentile(interior, 95.0) + 1e-6;
    return std::make_pair(avg, scale);
}

// ports grid.py::stone_alignment_score — SIGNED lattice-vs-cell-center
// contrast of disk-averaged 'stoneness'.
//
// Stones sit only on lattice points, and cell centers are never covered —
// but only under the TRUE offset and spacing: a half-spacing-shifted or
// sub-sampled lattice puts hypothesized cell centers inside stones, which
// drives the contrast to zero or NEGATIVE. Keeping the sign is what lets
// this term veto half-lattice comb solutions on dense boards.
double stone_alignment_score(const cv::Mat& avg, double scale, int n, double ox,
                             double sx, double oy, double sy) {
    // sample(points): avg[clip(round(y)), clip(round(x))].mean() (float64)
    const auto sample = [&avg](const std::vector<std::pair<double, double>>& points) {
        std::vector<double> vals;
        vals.reserve(points.size());
        for (const std::pair<double, double>& pt : points) {
            int x = static_cast<int>(np_round(pt.first));
            int y = static_cast<int>(np_round(pt.second));
            x = std::min(std::max(x, 0), avg.cols - 1);
            y = std::min(std::max(y, 0), avg.rows - 1);
            vals.push_back(avg.at<double>(y, x));
        }
        return np_mean(vals.data(), vals.size());
    };
    // lattice = [[ox + kx*sx, oy + ky*sy] for kx in ks for ky in ks]  (kx OUTER)
    std::vector<std::pair<double, double>> lattice;
    lattice.reserve(static_cast<size_t>(n) * n);
    for (int kx = 0; kx < n; ++kx) {
        for (int ky = 0; ky < n; ++ky) {
            lattice.emplace_back(ox + kx * sx, oy + ky * sy);
        }
    }
    // kc = np.arange(n - 1) + 0.5
    std::vector<std::pair<double, double>> cells;
    cells.reserve(static_cast<size_t>(n - 1) * (n - 1));
    for (int kx = 0; kx < n - 1; ++kx) {
        for (int ky = 0; ky < n - 1; ++ky) {
            cells.emplace_back(ox + (kx + 0.5) * sx, oy + (ky + 0.5) * sy);
        }
    }
    return (sample(lattice) - sample(cells)) / scale;
}

// ports grid.py::_stone_offset_candidates — dense-board rescue: keep each
// distinct candidate spacing but re-fit the offset on the stoneness
// projection — the ridge profile peaks at inter-stone gaps ~half a spacing
// off the lattice, while the stoneness projection peaks ON it, so the true
// offset gets back into the running.
std::vector<Cand> _stone_offset_candidates(const std::vector<double>& stone_prof,
                                           const cv::Mat& prof,
                                           const std::vector<double>& peaks, int n,
                                           const std::vector<Cand>& cands) {
    std::vector<Cand> extra;
    std::vector<double> spacings;
    for (const Cand& c : cands) {
        bool distinct = true;
        for (double s2 : spacings) {
            if (!(std::fabs(c.s - s2) > 0.05 * c.s)) {
                distinct = false;
                break;
            }
        }
        if (distinct) spacings.push_back(c.s);
    }
    const int splen = static_cast<int>(stone_prof.size());
    for (double s : spacings) {
        bool has_best_o = false;  // best_o = None
        double best_o = 0.0;
        double best_v = -std::numeric_limits<double>::infinity();
        for (double o : np_arange(RECT_PAD - 8.0, RECT_PAD + (SPAN - (n - 1) * s) + 8.0, 1.0)) {
            // v = stone_prof[clip(round(o + s*arange(n)), 0, len-1)].mean() (float64)
            std::vector<double> gathered(static_cast<size_t>(n));
            for (int kk = 0; kk < n; ++kk) {
                int idx = static_cast<int>(np_round(o + s * kk));
                idx = std::min(std::max(idx, 0), splen - 1);
                gathered[static_cast<size_t>(kk)] = stone_prof[static_cast<size_t>(idx)];
            }
            const double v = np_mean(gathered.data(), gathered.size());
            if (v > best_v) {
                best_v = v;
                best_o = o;
                has_best_o = true;
            }
        }
        if (has_best_o) {
            bool distinct = true;
            const std::vector<Cand>* groups[2] = {&cands, &extra};  // cands + extra
            for (const std::vector<Cand>* group : groups) {
                for (const Cand& c : *group) {
                    if (!(std::fabs(best_o - c.o) > 0.15 * s || std::fabs(s - c.s) > 0.05 * s)) {
                        distinct = false;
                        break;
                    }
                }
                if (!distinct) break;
            }
            if (distinct) {
                extra.push_back({_penalized(prof, peaks, n, best_o, s), best_o, s});
            }
        }
    }
    return extra;
}

// ports grid.py::_continuation_count — ends where the ridge lattice continues
// one spacing beyond the comb — evidence the quad frames a sub-window of a
// larger grid (e.g. a 9x9 window bounded by interior lines of a 13x13 board).
int _continuation_count(const cv::Mat& full_x, const cv::Mat& full_y, int n,
                        double ox, double sx, double oy, double sy) {
    int cnt = 0;
    const cv::Mat* profs[2] = {&full_x, &full_y};
    const double os[2] = {ox, oy};
    const double ss[2] = {sx, sy};
    for (int axis = 0; axis < 2; ++axis) {
        const cv::Mat& prof = *profs[axis];
        const double o = os[axis];
        const double s = ss[axis];
        const float* p = prof_ptr(prof);
        const int len = prof_len(prof);
        const std::vector<float> teeth = gather_teeth(p, len, n, o, s);
        const float tooth = np_mean(teeth.data(), teeth.size()) + 1e-9f;
        // a continuation must also be a significant peak in ABSOLUTE terms —
        // on dense boards the mean tooth strength is tiny, and slab-edge or
        // table ridges would otherwise fire relative to it
        const int a = RECT_PAD / 2;
        std::vector<float> inner(p + a, p + (len - a));
        const cv::Mat innerMat(1, static_cast<int>(inner.size()), CV_32F, inner.data());
        const float med = static_cast<float>(np_median(innerMat));
        const float perc = np_percentile(inner, 99.5);
        const float thr_abs = med + 0.30f * (perc - med);
        const int w = std::max(2, static_cast<int>(np_round(0.06 * s)));
        const double ends[2] = {o - s, o + n * s};
        for (double e : ends) {
            if (e < w + 1 || e > len - w - 2) {
                continue;  // beyond the rectified frame: unknowable
            }
            if (std::min(std::fabs(e - RECT_PAD), std::fabs(e - (RECT_PAD + SPAN))) < 12) {
                continue;  // wood/table step strip lives at the quad edge
            }
            const int c = static_cast<int>(np_round(e));
            // v = prof[c - w : c + w + 1].max()
            float v = p[c - w];
            for (int i = c - w + 1; i <= c + w; ++i) v = std::max(v, p[i]);
            if (v > static_cast<float>(CONT_THR) * tooth && v > thr_abs) ++cnt;
        }
    }
    return cnt;
}

// ports grid.py::_weak_teeth — count comb teeth with NEITHER a line response
// NOR stones along them.
//
// A real grid line is either visible or hidden UNDER stones — a line
// position with neither is a phantom. This is what rejects full-spacing
// comb shifts on dense boards, where the vacated outer line is covered
// (no peak to leave unexplained) and a one-spacing shift keeps cell
// centers on the true half-integer grid (no contrast signal).
int _weak_teeth(const cv::Mat& avg, double scale, const cv::Mat& prof_x,
                const cv::Mat& prof_y, int n, double ox, double sx, double oy,
                double sy) {
    const float* px = prof_ptr(prof_x);
    const float* py = prof_ptr(prof_y);
    const float norm_x = np_mean(px, static_cast<size_t>(prof_len(prof_x))) + 1e-9f;
    const float norm_y = np_mean(py, static_cast<size_t>(prof_len(prof_y))) + 1e-9f;
    std::vector<int> xi(static_cast<size_t>(n)), yi(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        int x = static_cast<int>(np_round(ox + sx * k));
        int y = static_cast<int>(np_round(oy + sy * k));
        xi[static_cast<size_t>(k)] = std::min(std::max(x, 0), avg.cols - 1);
        yi[static_cast<size_t>(k)] = std::min(std::max(y, 0), avg.rows - 1);
    }
    // stone_cols = avg[yi[:, None], xi[None, :]] / scale  # [row, col]
    std::vector<double> stone_cols(static_cast<size_t>(n) * n);
    for (int r = 0; r < n; ++r) {
        for (int c = 0; c < n; ++c) {
            stone_cols[static_cast<size_t>(r) * n + c] =
                avg.at<double>(yi[static_cast<size_t>(r)], xi[static_cast<size_t>(c)]) / scale;
        }
    }
    int weak = 0;
    std::vector<double> line(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        // if prof_x[xi[k]] / norm_x < 0.8 and stone_cols[:, k].mean() < 0.12
        if (px[xi[static_cast<size_t>(k)]] / norm_x < 0.8f) {
            for (int r = 0; r < n; ++r) line[static_cast<size_t>(r)] = stone_cols[static_cast<size_t>(r) * n + k];
            if (np_mean(line.data(), line.size()) < 0.12) ++weak;
        }
        // if prof_y[yi[k]] / norm_y < 0.8 and stone_cols[k, :].mean() < 0.12
        if (py[yi[static_cast<size_t>(k)]] / norm_y < 0.8f) {
            for (int c = 0; c < n; ++c) line[static_cast<size_t>(c)] = stone_cols[static_cast<size_t>(k) * n + c];
            if (np_mean(line.data(), line.size()) < 0.12) ++weak;
        }
    }
    return weak;
}

// ports grid.py::snap_lines — snap comb teeth to nearby profile maxima
// (sub-pixel) where a clear peak exists.
//
// The window is deliberately tight (±0.15 spacing): snapping refines an
// already-correct comb; a wider window would let spurious peaks capture
// teeth whose true line is hidden under stones.
std::vector<double> snap_lines(const cv::Mat& prof, const std::vector<double>& positions,
                               double spacing) {
    const float* p = prof_ptr(prof);
    const int len = prof_len(prof);
    std::vector<double> out = positions;
    const int half = std::max(2, static_cast<int>(np_round(0.15 * spacing)));
    // ref = np.median(prof) + 1e-9  (float32)
    const float ref = static_cast<float>(np_median(prof)) + 1e-9f;
    for (size_t k = 0; k < positions.size(); ++k) {
        const int c = static_cast<int>(np_round(positions[k]));  // round() is half-to-even
        const int lo = std::max(c - half, 1);
        const int hi = std::min(c + half + 1, len - 1);
        if (lo >= hi) {
            // np.argmax of an empty slice raises ValueError in Python;
            // unreachable for in-frame positions, but do not fall into UB.
            throw std::runtime_error("attempt to get argmax of an empty sequence");
        }
        // j = int(np.argmax(w)) — first occurrence of the maximum
        int j = 0;
        for (int i = 1; i < hi - lo; ++i) {
            if (p[lo + i] > p[lo + j]) j = i;
        }
        if (p[lo + j] < 3.0f * ref) continue;
        const int i = lo + j;
        // denom = prof[i-1] - 2*prof[i] + prof[i+1]  (float32)
        const float denom = (p[i - 1] - 2.0f * p[i]) + p[i + 1];
        if (std::fabs(denom) < 1e-9f) {
            // delta = 0.0 (python float) -> out[k] = i + 0.0 in float64
            out[k] = static_cast<double>(i);
        } else {
            // delta = 0.5 * (prof[i-1] - prof[i+1]) / denom  (float32)
            float delta = 0.5f * (p[i - 1] - p[i + 1]) / denom;
            // np.clip(delta, -1.0, 1.0) stays float32; i + float32 is a
            // float32 ADD (NEP 50 weak int), so the stored float64 value is
            // the float32 sum.
            if (delta < -1.0f) delta = -1.0f;
            if (delta > 1.0f) delta = 1.0f;
            out[k] = static_cast<double>(static_cast<float>(i) + delta);
        }
    }
    return out;
}

}  // namespace

// ports grid.py::rectify_quad — warp so `quad` (TL,TR,BR,BL) maps to the
// centered canonical square. Returns (rectified, H) with H mapping
// image -> canonical pixels.
std::pair<cv::Mat, cv::Mat> rectify_quad(const cv::Mat& gray, const cv::Mat& quad,
                                         int span, int pad) {
    CV_Assert(quad.rows == 4 && quad.cols == 2);
    const float fpad = static_cast<float>(pad);
    const float fps = static_cast<float>(pad + span);
    const cv::Point2f dst[4] = {{fpad, fpad}, {fps, fpad}, {fps, fps}, {fpad, fps}};
    // quad.astype(np.float32)
    cv::Mat quadf;
    quad.convertTo(quadf, CV_32F);
    cv::Point2f src[4];
    for (int i = 0; i < 4; ++i) {
        src[i] = cv::Point2f(quadf.at<float>(i, 0), quadf.at<float>(i, 1));
    }
    const cv::Mat H = cv::getPerspectiveTransform(src, dst);  // CV_64F 3x3
    const int side = span + 2 * pad;
    cv::Mat rect;
    cv::warpPerspective(gray, rect, H, cv::Size(side, side));
    return std::make_pair(rect, H);
}

// ports grid.py::line_profiles.
std::pair<cv::Mat, cv::Mat> line_profiles(const cv::Mat& rect, int pad, int span,
                                          bool mask) {
    // f = rect if rect.dtype == np.uint8 else np.clip(rect, 0, 255).astype(np.uint8)
    cv::Mat f;
    if (rect.type() == CV_8U) {
        f = rect;
    } else {
        // astype(np.uint8) truncates toward zero (values already clipped to
        // [0, 255], so plain truncation matches). Dead branch in the pipeline
        // (warpPerspective of uint8 stays uint8) but ported faithfully.
        cv::Mat asDouble;
        rect.convertTo(asDouble, CV_64F);
        f.create(rect.rows, rect.cols, CV_8U);
        for (int i = 0; i < f.rows; ++i) {
            const double* src = asDouble.ptr<double>(i);
            unsigned char* dst = f.ptr<unsigned char>(i);
            for (int j = 0; j < f.cols; ++j) {
                double v = src[j];
                if (v < 0.0) v = 0.0;
                if (v > 255.0) v = 255.0;
                dst[j] = static_cast<unsigned char>(v);
            }
        }
    }
    const int lo = pad;
    const int hi = pad + span;
    // L = 13: longer than any plausible line width, shorter than any stone
    // (hoisted to gr_constants.h::L).
    cv::Mat bh_v;
    cv::Mat bh_h;
    cv::morphologyEx(f, bh_v, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(L, 1)));
    cv::morphologyEx(f, bh_h, cv::MORPH_BLACKHAT,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(1, L)));
    // prof_x = bh_v[lo:hi, :].astype(np.float32).sum(axis=0)
    // prof_y = bh_h[:, lo:hi].astype(np.float32).sum(axis=1)
    // Sums of uint8 values are exact in float32 (< 2^24), so accumulation
    // order cannot matter; plain row-major loops.
    cv::Mat prof_x = cv::Mat::zeros(1, f.cols, CV_32F);
    cv::Mat prof_y = cv::Mat::zeros(1, f.rows, CV_32F);
    float* pxp = prof_x.ptr<float>(0);
    float* pyp = prof_y.ptr<float>(0);
    for (int i = lo; i < hi; ++i) {
        const unsigned char* row = bh_v.ptr<unsigned char>(i);
        for (int j = 0; j < f.cols; ++j) pxp[j] += row[j];
    }
    for (int i = 0; i < f.rows; ++i) {
        const unsigned char* row = bh_h.ptr<unsigned char>(i);
        float s = 0.0f;
        for (int j = lo; j < hi; ++j) s += row[j];
        pyp[i] = s;
    }
    for (cv::Mat* profp : {&prof_x, &prof_y}) {
        cv::Mat& prof = *profp;
        float* p = prof.ptr<float>(0);
        const int len = prof.cols;
        // p -= np.median(p)  (float32 median of a float32 array)
        const float med = static_cast<float>(np_median(prof));
        for (int j = 0; j < len; ++j) p[j] -= med;
        // np.clip(p, 0.0, None, out=p)
        for (int j = 0; j < len; ++j) {
            if (p[j] < 0.0f) p[j] = 0.0f;
        }
        if (mask) {
            // the wood/table step at the quad boundary leaves a blackhat strip
            // just OUTSIDE the quad; grid lines only live inside it
            // p[:lo] = 0.0 ; p[hi + 1:] = 0.0  (index hi itself stays live)
            for (int j = 0; j < lo; ++j) p[j] = 0.0f;
            for (int j = hi + 1; j < len; ++j) p[j] = 0.0f;
        }
    }
    return std::make_pair(prof_x, prof_y);
}

// ports grid.py::choose_size.
SizeResult choose_size(const cv::Mat& rect, const std::vector<int>& sizes) {
    const std::pair<cv::Mat, cv::Mat> profs = line_profiles(rect);
    const cv::Mat& prof_x = profs.first;
    const cv::Mat& prof_y = profs.second;
    const std::pair<cv::Mat, cv::Mat> fulls = line_profiles(rect, RECT_PAD, SPAN, false);
    const cv::Mat& full_x = fulls.first;
    const cv::Mat& full_y = fulls.second;
    const std::vector<double> peaks_x = _profile_peaks(prof_x, 0.6 * SPAN / 20);
    const std::vector<double> peaks_y = _profile_peaks(prof_y, 0.6 * SPAN / 20);
    // best per size: (total, ox, sx, oy, sy)
    struct Best {
        double total, ox, sx, oy, sy;
    };
    std::vector<std::pair<int, Best>> results;  // dict insertion order = sizes order
    for (int n : sizes) {
        std::vector<Cand> cands_x = _comb_candidates(prof_x, n, peaks_x);
        std::vector<Cand> cands_y = _comb_candidates(prof_y, n, peaks_y);
        const double s_mid = SPAN / (n - 1 + MAX_MARGIN);
        const std::pair<cv::Mat, double> sm = stoneness_map(rect, s_mid);
        const cv::Mat& avg = sm.first;
        const double scale = sm.second;
        // sp_x = avg[PAD:PAD+SPAN, :].mean(axis=0)  (float64; numpy's axis-0
        // reduction accumulates rows naively in order — verified)
        std::vector<double> sp_x(static_cast<size_t>(avg.cols), 0.0);
        for (int i = RECT_PAD; i < RECT_PAD + SPAN; ++i) {
            const double* row = avg.ptr<double>(i);
            for (int j = 0; j < avg.cols; ++j) sp_x[static_cast<size_t>(j)] += row[j];
        }
        for (size_t j = 0; j < sp_x.size(); ++j) sp_x[j] /= SPAN;
        // sp_y = avg[:, PAD:PAD+SPAN].mean(axis=1)  (contiguous reduce axis ->
        // numpy pairwise summation — verified)
        std::vector<double> sp_y(static_cast<size_t>(avg.rows));
        for (int i = 0; i < avg.rows; ++i) {
            sp_y[static_cast<size_t>(i)] = np_mean(avg.ptr<double>(i) + RECT_PAD, SPAN);
        }
        const std::vector<Cand> extra_x = _stone_offset_candidates(sp_x, prof_x, peaks_x, n, cands_x);
        cands_x.insert(cands_x.end(), extra_x.begin(), extra_x.end());
        const std::vector<Cand> extra_y = _stone_offset_candidates(sp_y, prof_y, peaks_y, n, cands_y);
        cands_y.insert(cands_y.end(), extra_y.begin(), extra_y.end());
        bool haveBest = false;  // best = None
        Best best = {0, 0, 0, 0, 0};
        for (const Cand& cx : cands_x) {
            for (const Cand& cy : cands_y) {
                const double stone = stone_alignment_score(avg, scale, n, cx.o, cx.s, cy.o, cy.s);
                const int weak = _weak_teeth(avg, scale, prof_x, prof_y, n, cx.o, cx.s, cy.o, cy.s);
                const double total =
                    cx.score + cy.score + STONE_WEIGHT * stone - WEAK_TOOTH_PENALTY * weak;
                if (!haveBest || total > best.total) {
                    best = {total, cx.o, cx.s, cy.o, cy.s};
                    haveBest = true;
                }
            }
        }
        results.push_back(std::make_pair(n, best));
    }
    // ranked = sorted(results.items(), key=lambda kv: -kv[1][0]) — stable, so
    // ties keep the sizes-iteration (insertion) order.
    std::vector<std::pair<int, Best>> ranked = results;
    std::stable_sort(ranked.begin(), ranked.end(),
                     [](const std::pair<int, Best>& a, const std::pair<int, Best>& b) {
                         return a.second.total > b.second.total;
                     });
    const int n_best = ranked.at(0).first;
    const Best& bb = ranked.at(0).second;
    const double second = ranked.at(1).second.total;  // IndexError if < 2 sizes
    // a lattice that continues past the comb ends means we are looking at a
    // sub-window of a larger board — collapse the margin so this candidate
    // loses arbitration (or fails loudly) instead of reporting a wrong size
    const int cont = _continuation_count(full_x, full_y, n_best, bb.ox, bb.sx, bb.oy, bb.sy);
    std::vector<double> pos_x(static_cast<size_t>(n_best));
    std::vector<double> pos_y(static_cast<size_t>(n_best));
    for (int k = 0; k < n_best; ++k) {
        pos_x[static_cast<size_t>(k)] = bb.ox + bb.sx * k;
        pos_y[static_cast<size_t>(k)] = bb.oy + bb.sy * k;
    }
    SizeResult res;
    res.board_size = n_best;
    res.xs = snap_lines(prof_x, pos_x, bb.sx);
    res.ys = snap_lines(prof_y, pos_y, bb.sy);
    res.score = bb.total;
    res.margin = bb.total - second - CONT_PENALTY * cont;
    for (const std::pair<int, Best>& kv : results) {
        res.scores[kv.first] = kv.second.total;
    }
    return res;
}

// ---- Test/diagnostic bridge (declared in GobanRecogTestBridge.hpp) ---------
// Defined HERE, not in gr_testbridge.cpp, so the wrappers can reach the
// file-local statics above without widening gr_grid.h's surface.

namespace testbridge {

namespace {

void append_double(std::string& out, double v) {
    if (std::isnan(v)) {
        out += "NaN";
        return;
    }
    if (std::isinf(v)) {
        out += (v > 0 ? "Infinity" : "-Infinity");
        return;
    }
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

void append_array_f32(std::string& out, const float* v, size_t n) {
    out += '[';
    for (size_t i = 0; i < n; ++i) {
        if (i) out += ", ";
        append_double(out, static_cast<double>(v[i]));  // f32 -> f64 is exact
    }
    out += ']';
}

}  // namespace

int grid_profile_peaks(const float* prof, int profLen, double minSep, double* out) {
    const cv::Mat m(1, profLen, CV_32F, const_cast<float*>(prof));
    const std::vector<double> peaks = gobanrecog::_profile_peaks(m, minSep);
    for (size_t i = 0; i < peaks.size(); ++i) out[i] = peaks[i];
    return static_cast<int>(peaks.size());
}

double grid_penalized(const float* prof, int profLen, const double* peaks,
                      int peaksLen, int n, double o, double s) {
    const cv::Mat m(1, profLen, CV_32F, const_cast<float*>(prof));
    const std::vector<double> pk(peaks, peaks + peaksLen);
    return gobanrecog::_penalized(m, pk, n, o, s);
}

int grid_comb_candidates(const float* prof, int profLen, const double* peaks,
                         int peaksLen, int n, int k, double* outTriples) {
    const cv::Mat m(1, profLen, CV_32F, const_cast<float*>(prof));
    const std::vector<double> pk(peaks, peaks + peaksLen);
    const std::vector<Cand> cands = gobanrecog::_comb_candidates(m, n, pk, k);
    for (size_t i = 0; i < cands.size(); ++i) {
        outTriples[3 * i + 0] = cands[i].score;
        outTriples[3 * i + 1] = cands[i].o;
        outTriples[3 * i + 2] = cands[i].s;
    }
    return static_cast<int>(cands.size());
}

int grid_weak_teeth(const double* avg, int rows, int cols, double scale,
                    const float* profX, int lenX, const float* profY, int lenY,
                    int n, double ox, double sx, double oy, double sy) {
    const cv::Mat avgMat(rows, cols, CV_64F, const_cast<double*>(avg));
    const cv::Mat px(1, lenX, CV_32F, const_cast<float*>(profX));
    const cv::Mat py(1, lenY, CV_32F, const_cast<float*>(profY));
    return gobanrecog::_weak_teeth(avgMat, scale, px, py, n, ox, sx, oy, sy);
}

void grid_snap_lines(const float* prof, int profLen, const double* positions,
                     int n, double spacing, double* out) {
    const cv::Mat m(1, profLen, CV_32F, const_cast<float*>(prof));
    const std::vector<double> pos(positions, positions + n);
    const std::vector<double> snapped = gobanrecog::snap_lines(m, pos, spacing);
    for (int i = 0; i < n; ++i) out[i] = snapped[static_cast<size_t>(i)];
}

std::string grid_stage_json(const unsigned char* img, int width, int height,
                            const double* quad8) {
    const cv::Mat gray(height, width, CV_8U, const_cast<unsigned char*>(img));
    cv::Mat rect;
    cv::Mat H;
    if (quad8 != nullptr) {
        const cv::Mat quad(4, 2, CV_64F, const_cast<double*>(quad8));
        const std::pair<cv::Mat, cv::Mat> rh = gobanrecog::rectify_quad(gray, quad);
        rect = rh.first;
        H = rh.second;
    } else {
        rect = gray;
    }
    const std::pair<cv::Mat, cv::Mat> profs = gobanrecog::line_profiles(rect);
    const std::pair<cv::Mat, cv::Mat> fulls =
        gobanrecog::line_profiles(rect, RECT_PAD, SPAN, false);
    const std::vector<double> peaks_x = gobanrecog::_profile_peaks(profs.first, 0.6 * SPAN / 20);
    const std::vector<double> peaks_y = gobanrecog::_profile_peaks(profs.second, 0.6 * SPAN / 20);
    const SizeResult res = gobanrecog::choose_size(rect);

    std::string out;
    out.reserve(1 << 16);
    out += "{\"rect_width\": " + std::to_string(rect.cols);
    out += ", \"rect_height\": " + std::to_string(rect.rows);
    if (!H.empty()) {
        out += ", \"H\": ";
        double h9[9];
        for (int i = 0; i < 9; ++i) h9[i] = H.at<double>(i / 3, i % 3);
        append_array(out, h9, 9);
    }
    out += ", \"board_size\": " + std::to_string(res.board_size);
    out += ", \"score\": ";
    append_double(out, res.score);
    out += ", \"margin\": ";
    append_double(out, res.margin);
    out += ", \"scores\": {";
    bool first = true;
    for (std::map<int, double>::const_iterator it = res.scores.begin(); it != res.scores.end(); ++it) {
        if (!first) out += ", ";
        first = false;
        out += "\"" + std::to_string(it->first) + "\": ";
        append_double(out, it->second);
    }
    out += "}, \"xs\": ";
    append_array(out, res.xs.data(), res.xs.size());
    out += ", \"ys\": ";
    append_array(out, res.ys.data(), res.ys.size());
    out += ", \"peaks_x\": ";
    append_array(out, peaks_x.data(), peaks_x.size());
    out += ", \"peaks_y\": ";
    append_array(out, peaks_y.data(), peaks_y.size());
    out += ", \"prof_x\": ";
    append_array_f32(out, profs.first.ptr<float>(0), profs.first.total());
    out += ", \"prof_y\": ";
    append_array_f32(out, profs.second.ptr<float>(0), profs.second.total());
    out += ", \"full_x\": ";
    append_array_f32(out, fulls.first.ptr<float>(0), fulls.first.total());
    out += ", \"full_y\": ";
    append_array_f32(out, fulls.second.ptr<float>(0), fulls.second.total());
    out += "}";
    return out;
}

int grid_rectify(const unsigned char* gray, int width, int height,
                 const double* quad8, unsigned char* outRect, double* outH9) {
    const cv::Mat grayMat(height, width, CV_8U, const_cast<unsigned char*>(gray));
    const cv::Mat quad(4, 2, CV_64F, const_cast<double*>(quad8));
    const std::pair<cv::Mat, cv::Mat> rh = gobanrecog::rectify_quad(grayMat, quad);
    const cv::Mat& rect = rh.first;
    CV_Assert(rect.isContinuous());
    const size_t bytes = rect.total();
    std::copy(rect.ptr<unsigned char>(0), rect.ptr<unsigned char>(0) + bytes, outRect);
    for (int i = 0; i < 9; ++i) outH9[i] = rh.second.at<double>(i / 3, i % 3);
    return rect.cols;
}

}  // namespace testbridge

}  // namespace gobanrecog
