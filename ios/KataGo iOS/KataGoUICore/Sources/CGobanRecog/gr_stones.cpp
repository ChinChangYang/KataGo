//
//  gr_stones.cpp
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/stones.py line-by-line (port-conventions.md
//  rule 1). Only {StoneClassification, classify_stones} are exposed via
//  gr_stones.h (run.py's import surface); every other stones.py function is
//  file-local here. The gobanrecog::testbridge stones_* wrappers are ALSO
//  defined at the bottom of this file (not in gr_testbridge.cpp) so they can
//  reach the file-local statics — the sanctioned cv-free test/diagnostic seam
//  (pattern established by gr_grid.cpp, Task 4).
//
//  dtype fidelity (rule 2), all verified against numpy 2.5.1 in the reference
//  venv (Task 5 probes):
//    - rect = warp(uint8).astype(np.float32) -> CV_32FC3; gray =
//      cvtColor(rect, BGR2GRAY) is float32 in, float32 out.
//    - denom = rect.sum(axis=2) + 3.0 is float32: the axis-2 (contiguous,
//      n=3 < 8) reduction is a naive left-to-right f32 sum ((b+g)+r), and
//      NEP 50 keeps np.float32 + python-float in float32. All u8-derived
//      addends are exact in f32, so the value is order-independent anyway.
//    - warmth = (rect[:,:,2] - rect[:,:,0]) / denom is float32 (one rounding
//      in the subtraction — exact for u8-derived values — one in the divide).
//    - np.median over a fancy-indexed float32 disk sample is a float32 scalar
//      (np_median's CV_32F path); float(...) promotes it exactly to double.
//    - cell_l/cell_c are np.zeros((n-1, n-1)) -> float64; their 4x4-slice
//      medians (wood_l/wood_c) are float64 medians.
//    - everything after the medians (dev/ratio/gap/margins) is Python-float
//      double arithmetic.
//    - int(round(...)) is half-to-even -> np_round (every rounded value here
//      is an exact integer or non-half fraction, but the port keeps the call).
//
//  BGR channel order is load-bearing (rule 11): warmth = (channel 2 - channel
//  0) / (sum + 3) — channel 2 is R and channel 0 is B under BGR. Never
//  reorder.
//

#include "gr_stones.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include "GobanRecogTestBridge.hpp"
#include "gr_constants.h"
#include "gr_parity.h"

// numpy never fuses multiply-add into FMA (each op rounds separately); forbid
// contraction so the float32 warmth arithmetic rounds like numpy's.
#pragma STDC FP_CONTRACT OFF

namespace gobanrecog {

namespace {

// stones.py:18 `SPACING = 32` — hoisted to gr_constants.h as SP (the Python
// source duplicates the 32/48 frame across modules). A local alias keeps this
// port line-diffable against stones.py; PAD is the same name in gr_constants.h.
constexpr int SPACING = SP;

// ports stones.py::_rectify_lattice
// """Warp so grid point (c, r) lands at (PAD + c*SPACING, PAD + r*SPACING)."""
// out_M (optional) receives M = A @ inv(H_grid) for the parity harness.
// numpy's `A @ np.linalg.inv(H_grid)` matmul equals the left-to-right
// (a0*b0 + a1*b1) + a2*b2 order bit-for-bit (venv-verified); np.linalg.inv
// vs inv3x3 (cv::invert closed form) differ by ~1 ULP (2.2e-16 rel measured),
// which did not change a single warped byte on the probe image.
cv::Mat _rectify_lattice(const cv::Mat& img_bgr, const cv::Mat& H_grid, int n,
                         cv::Mat* out_M = nullptr) {
    // A = [[SPACING, 0.0, PAD], [0.0, SPACING, PAD], [0.0, 0.0, 1.0]] (float64)
    const double A[3][3] = {{static_cast<double>(SPACING), 0.0, static_cast<double>(PAD)},
                            {0.0, static_cast<double>(SPACING), static_cast<double>(PAD)},
                            {0.0, 0.0, 1.0}};
    const cv::Mat inv = inv3x3(H_grid);  // np.linalg.inv(H_grid)
    cv::Mat M(3, 3, CV_64F);
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            // numpy's 3-element dot: left-to-right, no FMA (venv-verified).
            M.at<double>(i, j) = (A[i][0] * inv.at<double>(0, j) +
                                  A[i][1] * inv.at<double>(1, j)) +
                                 A[i][2] * inv.at<double>(2, j);
        }
    }
    const int side = 2 * PAD + (n - 1) * SPACING;
    cv::Mat out;
    // cv2.warpPerspective defaults: INTER_LINEAR, BORDER_CONSTANT 0 — same in C++.
    cv::warpPerspective(img_bgr, out, M, cv::Size(side, side));
    if (out_M != nullptr) *out_M = M;
    return out;
}

// ports stones.py::_disk_indices
//   yy, xx = np.mgrid[-radius:radius+1, -radius:radius+1]
//   m = xx**2 + yy**2 <= radius**2
//   return yy[m], xx[m]
// The boolean mask selects in C (row-major) order: yy outer ascending, xx
// inner ascending. Order is irrelevant to the medians but preserved anyway.
std::pair<std::vector<int>, std::vector<int>> _disk_indices(int radius) {
    std::vector<int> yy;
    std::vector<int> xx;
    for (int y = -radius; y <= radius; ++y) {
        for (int x = -radius; x <= radius; ++x) {
            if (x * x + y * y <= radius * radius) {
                yy.push_back(y);
                xx.push_back(x);
            }
        }
    }
    return {yy, xx};
}

// ports stones.py::_w_fires
// """Shared three-rule white condition, used both per-offset (to build
// best_w_margin) and in the decision branch. The two call sites must stay
// semantically identical: a decided-W node reaches `margin = best_w_margin`
// on the assumption that the deciding sample itself fired this rule, so a
// divergence between them can leave best_w_margin None -> TypeError. wood_c
// is a parameter (not a closure) because it is recomputed per grid node."""
//
// Rule 3 carries a near-neutral-wood guard `(wood_c > 0.10 || ratio > 1.20)`
// (both strict): on nearly achromatic wood the relative cooling test
// `mc < 0.65*wood_c` is close to vacuous, so a pale grain stripe or sheen
// band 10-16% brighter than local wood fires as a dim phantom white.
// Measured 2026-07-11 (see stones.py::_w_fires for the full numbers): zero
// canonical-600 labels flip; img0821's three phantoms (ratio 1.112-1.158 on
// wood_c 0.05-0.08) die; IMG_0811's blurred white `rl` is protected by the
// wood_c arm. Guard-suppressed firings are the legacy-vs-guarded delta that
// confidence_legacy and gr_run.cpp's two-tier floor arbitrate.
bool _w_fires(double gap, double ratio, double mc, double wood_c) {
    return (gap > 0.10 && ratio > 0.90) ||
           (gap > 0.055 && ratio > 1.00) ||
           (ratio > 1.10 && mc < 0.65 * wood_c && (wood_c > 0.10 || ratio > 1.20));
}

// ports stones.py::_w_fires_legacy — the pre-guard rule, kept ONLY to compute
// confidence_legacy so the two-tier acceptance can reproduce the historical
// abstain/accept bit exactly. Guarded firings are a strict subset of legacy
// firings (the guard only narrows rule 3).
bool _w_fires_legacy(double gap, double ratio, double mc, double wood_c) {
    return (gap > 0.10 && ratio > 0.90) ||
           (gap > 0.055 && ratio > 1.00) ||
           (ratio > 1.10 && mc < 0.65 * wood_c);
}

// stones.py:73-174 (classify_stones) with the rectified uint8 frame already
// computed: classify_stones = _rectify_lattice + this. Split so the
// micro-parity harness can inject Python's rect bytes unchanged (same-bytes
// leg) and record the per-node clamped margins; the `out_margins` store is
// the ONLY addition to the Python body.
StoneClassification _classify_rectified(const cv::Mat& rect_u8, int n,
                                        cv::Mat* out_margins) {
    CV_Assert(rect_u8.type() == CV_8UC3 && rect_u8.rows == rect_u8.cols);
    CV_Assert(rect_u8.rows == 2 * PAD + (n - 1) * SPACING);

    // rect = _rectify_lattice(img_bgr, H_grid, n).astype(np.float32)
    cv::Mat rect;
    rect_u8.convertTo(rect, CV_32FC3);
    // gray = cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY)   (float32 -> float32)
    cv::Mat gray;
    cv::cvtColor(rect, gray, cv::COLOR_BGR2GRAY);
    // normalized warmth: invariant to exposure, stable under white-balance
    // shifts because the same shift moves wood and stones together and wood
    // stays the warmest surface in the frame
    //   denom = rect.sum(axis=2) + 3.0
    //   warmth = (rect[:, :, 2] - rect[:, :, 0]) / denom
    // (all float32; channel 2 = R, channel 0 = B under BGR — load-bearing)
    const int side = rect_u8.rows;
    cv::Mat warmth(side, side, CV_32F);
    for (int y = 0; y < side; ++y) {
        const cv::Vec3f* row = rect.ptr<cv::Vec3f>(y);
        float* w = warmth.ptr<float>(y);
        for (int x = 0; x < side; ++x) {
            const float b = row[x][0];
            const float g = row[x][1];
            const float r = row[x][2];
            const float denom = ((b + g) + r) + 3.0f;  // np axis-2 sum: naive l-to-r
            w[x] = (r - b) / denom;
        }
    }

    // def at(c, r): return int(round(PAD + c*SPACING)), int(round(PAD + r*SPACING))
    const auto at = [](double c, double r) {
        return std::make_pair(static_cast<int>(np_round(PAD + c * SPACING)),
                              static_cast<int>(np_round(PAD + r * SPACING)));
    };

    // cell patches must stay inside the wood gap even on near-full boards
    const std::pair<std::vector<int>, std::vector<int>> cell_idx =
        _disk_indices(static_cast<int>(np_round(0.22 * SPACING)));
    const std::pair<std::vector<int>, std::vector<int>> node_idx =
        _disk_indices(static_cast<int>(np_round(0.36 * SPACING)));
    const std::vector<int>& cell_dy = cell_idx.first;
    const std::vector<int>& cell_dx = cell_idx.second;
    const std::vector<int>& node_dy = node_idx.first;
    const std::vector<int>& node_dx = node_idx.second;

    // np.median(gray[dy + y, dx + x]) — fancy-index gather then the float32
    // median (np_median's CV_32F path); float(...) promotes exactly to double.
    std::vector<float> scratch;
    const auto disk_median = [&scratch](const cv::Mat& m, const std::vector<int>& dy,
                                        const std::vector<int>& dx, int x, int y) {
        scratch.clear();
        for (size_t i = 0; i < dy.size(); ++i) {
            scratch.push_back(m.at<float>(y + dy[i], x + dx[i]));
        }
        const cv::Mat view(1, static_cast<int>(scratch.size()), CV_32F, scratch.data());
        return np_median(view);
    };

    // cell_l = np.zeros((n - 1, n - 1)); cell_c = np.zeros((n - 1, n - 1))
    cv::Mat cell_l = cv::Mat::zeros(n - 1, n - 1, CV_64F);
    cv::Mat cell_c = cv::Mat::zeros(n - 1, n - 1, CV_64F);
    for (int r = 0; r < n - 1; ++r) {
        for (int c = 0; c < n - 1; ++c) {
            const std::pair<int, int> xy = at(c + 0.5, r + 0.5);
            cell_l.at<double>(r, c) = disk_median(gray, cell_dy, cell_dx, xy.first, xy.second);
            cell_c.at<double>(r, c) = disk_median(warmth, cell_dy, cell_dx, xy.first, xy.second);
        }
    }

    // grid = [["."] * n for _ in range(n)]
    std::vector<std::vector<char>> grid(static_cast<size_t>(n),
                                        std::vector<char>(static_cast<size_t>(n), EMPTY));
    double min_margin = 1.0;
    double min_margin_legacy = 1.0;
    for (int r = 0; r < n; ++r) {
        for (int c = 0; c < n; ++c) {
            // local wood reference: median over the 3x3 block of adjacent
            // cells rides illumination gradients and shadow bands, and the
            // median survives a minority of stone-contaminated cells
            const int r0 = std::max(r - 2, 0);
            const int r1 = std::min(r + 2, n - 1);
            const int c0 = std::max(c - 2, 0);
            const int c1 = std::min(c + 2, n - 1);
            // wood_l = float(np.median(cell_l[r0:r1, c0:c1]))  — the Python
            // slice EXCLUDES r1/c1 (up to 4x4 cells interior, fewer at edges);
            // float64 median (mean of the middle two on even counts).
            std::vector<double> wl;
            std::vector<double> wc;
            wl.reserve(static_cast<size_t>((r1 - r0) * (c1 - c0)));
            wc.reserve(static_cast<size_t>((r1 - r0) * (c1 - c0)));
            for (int rr = r0; rr < r1; ++rr) {
                for (int cc = c0; cc < c1; ++cc) {
                    wl.push_back(cell_l.at<double>(rr, cc));
                    wc.push_back(cell_c.at<double>(rr, cc));
                }
            }
            const double wood_l = np_median(std::move(wl));
            const double wood_c = np_median(std::move(wc));
            // two-candidate arbitration. Darkness is the black discriminator
            // and takes priority: no pale surface fakes ratio < 0.5, so B
            // fires if the DARKEST offset is dark — a wood-glare disk can
            // out-|gap| a dark stone under the argmax-|gap| selection
            // (measured on IMG_0811 node (15,8): glare sample ratio 0.777
            // won selection over the stone sample at 0.370, reading a true
            // black as empty). W stays judged at the single most stone-like
            // sample: permissive ANY-offset W firing was measured to flip
            // dense blacks to W (rejected run: exact 0.9900, all errors
            // B->W on specular hard-tier boards). The reported margin is the
            // strongest evidence FOR the decided color across offsets, so a
            // stone solidly decided at one offset is not scored by an
            // unlucky sample (measured: img_00566 true black, searched ratio
            // 0.4984 -> margin 0.0031; center ratio 0.2549 -> 0.49). Empty
            // margins stay canonical-center so the search cannot depress
            // them.
            double med_l = 0.0;
            double med_c = 0.0;
            double best_dev = -1.0;
            double cen_l = 0.0;
            double cen_c = 0.0;
            double min_ratio = std::numeric_limits<double>::infinity();
            double min_ratio_c = 0.0;  // warmth of the darkest (min-ratio) sample
            // Two accumulators, NOT one: guarded-rule firings are a strict
            // subset of legacy firings, so a node can fire legacy-W at some
            // offset with no guarded firing (best_w_margin stays nullopt) —
            // the legacy margin leg below must not deref it. Each rule tracks
            // the max margin over ITS OWN firing offsets (stones.py lockstep).
            std::optional<double> best_w_margin;         // best_w_margin = None
            std::optional<double> best_w_margin_legacy;  // best_w_margin_legacy = None
            const std::vector<std::pair<double, double>>& offsets = nodeOffsets();
            for (size_t i = 0; i < offsets.size(); ++i) {
                const double dx = offsets[i].first;
                const double dy = offsets[i].second;
                const std::pair<int, int> xy = at(c + dx, r + dy);
                // ml = float(np.median(gray[node_dy + y, node_dx + x]))
                const double ml = disk_median(gray, node_dy, node_dx, xy.first, xy.second);
                const double mc = disk_median(warmth, node_dy, node_dx, xy.first, xy.second);
                if (i == 0) {  // _NODE_OFFSETS is sorted center-first: (0.0, 0.0)
                    cen_l = ml;
                    cen_c = mc;
                }
                const double dev = std::abs(wood_c - mc);
                if (dev > best_dev + 1e-9) {
                    med_l = ml;
                    med_c = mc;
                    best_dev = dev;
                }
                const double o_ratio = ml / std::max(wood_l, 1e-6);
                const double o_gap = wood_c - mc;
                // strict <: first-on-tie, like Python's min() with the
                // paired warmth tracked alongside
                if (o_ratio < min_ratio) {
                    min_ratio = o_ratio;
                    min_ratio_c = mc;
                }
                if (_w_fires_legacy(o_gap, o_ratio, mc, wood_c)) {
                    const double m = std::min(
                        1.0, std::max((o_gap - 0.055) / 0.05, (o_ratio - 1.10) / 0.4));
                    if (!best_w_margin_legacy.has_value() || m > *best_w_margin_legacy) {
                        best_w_margin_legacy = m;
                    }
                    if (_w_fires(o_gap, o_ratio, mc, wood_c)) {
                        if (!best_w_margin.has_value() || m > *best_w_margin) {
                            best_w_margin = m;
                        }
                    }
                }
            }
            const double ratio = med_l / std::max(wood_l, 1e-6);
            const double gap = wood_c - med_c;  // stones of either color are less warm than wood
            // the warmth gap is EVIDENCE for a white stone, not just a veto:
            // on bright wood, white-stone luminance overlaps empty-wood
            // luminance and no ratio threshold alone can separate them.
            // rule-3 multiplier 0.65 re-validated against the full
            // 600-image eval on this branch; 0.55 missed a blurred white
            // (IMG_0811 `rl`, med_c/wood_c = 0.63).
            double margin;
            double margin_legacy;
            // Steep-shadow veto on the black rule (real-photo IMG_0816); see
            // stones.py for the measured rationale: a narrow warm shadow band
            // puts EMPTY nodes at min_ratio 0.38-0.46 with RAISED normalized
            // warmth (mc/wood_c 1.28-1.40) — true blacks in the same darkness
            // zone (blurry IMG_0811) sit at 0.85-1.09. Threshold 1.18 threads
            // both; only 2 canonical true-B nodes have min_ratio >= 0.30 at
            // all (both on the already-degraded img_00440).
            const bool shadow_veto = min_ratio < 0.50 && min_ratio >= 0.35 &&
                                     wood_c > 0.0 && min_ratio_c > 1.18 * wood_c;
            // Every branch assigns BOTH margins: margin_legacy replays the
            // pre-guard elif chain (B -> legacy-W -> veto -> empty) exactly,
            // so confidence_legacy reproduces the historical value bit-for-bit
            // (stones.py lockstep).
            if (min_ratio < 0.50 && !shadow_veto) {
                grid[static_cast<size_t>(r)][static_cast<size_t>(c)] = BLACK;
                margin = (0.50 - min_ratio) / 0.50;
                margin_legacy = margin;
            } else if (_w_fires(gap, ratio, med_c, wood_c)) {
                grid[static_cast<size_t>(r)][static_cast<size_t>(c)] = WHITE;
                // cannot be None: the deciding sample itself fired a W rule
                // (.value() would throw std::bad_optional_access exactly where
                // Python's None would TypeError)
                margin = best_w_margin.value();
                // legacy is a superset: it fired here too, with its own max
                margin_legacy = best_w_margin_legacy.value();
            } else if (shadow_veto) {
                // Vetoed nodes are empty by POSITIVE evidence (warmth-raised
                // shadow); score that evidence — the canonical-center margin
                // below would be ~0 (the node IS dark) and one such node
                // would abstain the whole corrected board (see stones.py).
                margin = std::min(1.0, (min_ratio_c / wood_c - 1.18) / 0.22);
                margin_legacy = _w_fires_legacy(gap, ratio, med_c, wood_c)
                                    ? best_w_margin_legacy.value()
                                    : margin;
            } else {
                const double ratio_c = cen_l / std::max(wood_l, 1e-6);
                const double gap_c = wood_c - cen_c;
                margin = std::max(
                    0.0, std::min((ratio_c - 0.50) / 0.50,
                                  gap_c <= 0.055 ? 1.0 : (1.00 - ratio_c) / 0.10));
                margin_legacy = _w_fires_legacy(gap, ratio, med_c, wood_c)
                                    ? best_w_margin_legacy.value()
                                    : margin;
            }
            // min_margin = min(min_margin, max(0.0, min(1.0, margin)))
            const double clamped = std::max(0.0, std::min(1.0, margin));
            if (out_margins != nullptr) {
                out_margins->at<double>(r, c) = clamped;
            }
            min_margin = std::min(min_margin, clamped);
            min_margin_legacy =
                std::min(min_margin_legacy, std::max(0.0, std::min(1.0, margin_legacy)));
        }
    }
    return StoneClassification{BoardState::fromGrid(grid), min_margin, min_margin_legacy};
}

}  // namespace

// ports stones.py::classify_stones
StoneClassification classify_stones(const cv::Mat& img_bgr, const cv::Mat& H_grid, int n) {
    const cv::Mat rect_u8 = _rectify_lattice(img_bgr, H_grid, n);
    return _classify_rectified(rect_u8, n, nullptr);
}

// ---- Test/diagnostic bridge (declared in GobanRecogTestBridge.hpp) ---------
// Defined HERE, not in gr_testbridge.cpp, so the wrappers can reach the
// file-local statics above without widening gr_stones.h's surface.

namespace testbridge {

namespace {

// JSON emission helpers (duplicate gr_grid.cpp's file-local ones; candidates
// for a shared internal header once a third stage needs them).
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

}  // namespace

int stones_disk_indices(int radius, int* dy, int* dx) {
    const std::pair<std::vector<int>, std::vector<int>> idx =
        gobanrecog::_disk_indices(radius);
    for (size_t i = 0; i < idx.first.size(); ++i) {
        dy[i] = idx.first[i];
        dx[i] = idx.second[i];
    }
    return static_cast<int>(idx.first.size());
}

int stones_w_fires(double gap, double ratio, double mc, double wood_c) {
    return gobanrecog::_w_fires(gap, ratio, mc, wood_c) ? 1 : 0;
}

std::string stones_classify_rect(const unsigned char* rect, int side, int boardSize) {
    const cv::Mat rectMat(side, side, CV_8UC3, const_cast<unsigned char*>(rect));
    const StoneClassification cls =
        gobanrecog::_classify_rectified(rectMat, boardSize, nullptr);
    std::string out;
    for (size_t i = 0; i < cls.board.rows.size(); ++i) {
        if (i) out += '\n';
        out += cls.board.rows[i];
    }
    out += '|';
    append_double(out, cls.confidence);
    return out;
}

std::string stones_stage_json(const unsigned char* img, int width, int height,
                              const double* h9, int boardSize) {
    const cv::Mat imgMat(height, width, CV_8UC3, const_cast<unsigned char*>(img));
    cv::Mat rect_u8;
    cv::Mat M;
    if (h9 != nullptr) {
        const cv::Mat H(3, 3, CV_64F, const_cast<double*>(h9));
        rect_u8 = gobanrecog::_rectify_lattice(imgMat, H, boardSize, &M);
    } else {
        rect_u8 = imgMat;
    }
    cv::Mat margins(boardSize, boardSize, CV_64F);
    const StoneClassification cls =
        gobanrecog::_classify_rectified(rect_u8, boardSize, &margins);

    std::string out;
    out.reserve(1 << 15);
    out += "{\"stage\": \"stones\"";
    out += ", \"board_size\": " + std::to_string(boardSize);
    out += ", \"rect_width\": " + std::to_string(rect_u8.cols);
    out += ", \"rect_height\": " + std::to_string(rect_u8.rows);
    if (!M.empty()) {
        out += ", \"M\": ";
        double m9[9];
        for (int i = 0; i < 9; ++i) m9[i] = M.at<double>(i / 3, i % 3);
        append_array(out, m9, 9);
    }
    out += ", \"rows\": [";
    for (size_t i = 0; i < cls.board.rows.size(); ++i) {
        if (i) out += ", ";
        out += '"';
        out += cls.board.rows[i];  // only '.', 'B', 'W' — no JSON escaping needed
        out += '"';
    }
    out += "], \"confidence\": ";
    append_double(out, cls.confidence);
    out += ", \"confidence_legacy\": ";
    append_double(out, cls.confidence_legacy);
    out += ", \"margins\": [";
    for (int r = 0; r < boardSize; ++r) {
        if (r) out += ", ";
        append_array(out, margins.ptr<double>(r), static_cast<size_t>(boardSize));
    }
    out += "]}";
    return out;
}

int stones_rectify(const unsigned char* img, int width, int height,
                   const double* h9, int boardSize,
                   unsigned char* outRect, double* outM9) {
    const cv::Mat imgMat(height, width, CV_8UC3, const_cast<unsigned char*>(img));
    const cv::Mat H(3, 3, CV_64F, const_cast<double*>(h9));
    cv::Mat M;
    const cv::Mat rect = gobanrecog::_rectify_lattice(imgMat, H, boardSize, &M);
    CV_Assert(rect.isContinuous());
    const size_t bytes = rect.total() * rect.elemSize();
    std::copy(rect.ptr<unsigned char>(0), rect.ptr<unsigned char>(0) + bytes, outRect);
    for (int i = 0; i < 9; ++i) outM9[i] = M.at<double>(i / 3, i % 3);
    return rect.cols;
}

}  // namespace testbridge

}  // namespace gobanrecog
